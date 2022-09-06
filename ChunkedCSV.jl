using ScanByte
import Parsers
using TranscodingStreams # TODO: ditch this

# IDEA: We could make a 48bit PosLen string type (8MB -> 23 bits if we represent 8MB as 0, 2 bits for metadata)
# IDEA: Instead of having SoA layout in TaskResultBuffer, we could try AoS using Tuples of Refs (this might be more cache friendly?)

# TODO: Use information from initial buffer fill to see if we're deaing with a small file (and have a fast path for that)

"""
In bytes. This absolutely has to be larger than any single row.
Much safer if any two consecutive rows are smaller than this threshold.
"""
const BUFFER_SIZE = UInt32(8 * 1024 * 1024)  # 8 MiB

include("BufferedVectors.jl")
include("TaskResults.jl")

struct ParsingContext
    schema::Vector{DataType}
    header::Vector{Symbol}
    bytes::Vector{UInt8}
    eols::BufferedVector{UInt32}
    limit::UInt32
end

struct ParserSettings
    schema::Union{Nothing,Vector{DataType}}
    header::Union{Nothing,Vector{Symbol}}
    header_row::UInt32
    skiprows::UInt32
    limit::UInt32
end

readbytesall!(io::IO, buf, n) = UInt32(Base.readbytes!(io, buf, n; all = true))
readbytesall!(io::IOBuffer, buf, n) = UInt32(Base.readbytes!(io, buf, n))
function prepare_buffer!(io::IO, buf::Vector{UInt8}, last_chunk_newline_at)
    ptr = pointer(buf)
    if last_chunk_newline_at == 0 # this is the first time we saw the buffer, we'll just fill it up
        bytes_read_in = readbytesall!(io, buf, BUFFER_SIZE)
    elseif last_chunk_newline_at < BUFFER_SIZE
        # We'll keep the bytes that are past the last newline, shifting them to the left
        # and refill the rest of the buffer.
        unsafe_copyto!(ptr, ptr + last_chunk_newline_at, BUFFER_SIZE - last_chunk_newline_at)
        bytes_read_in = @inbounds readbytesall!(io, @view(buf[BUFFER_SIZE - last_chunk_newline_at:end]), last_chunk_newline_at)
    else
        # Last chunk was consumed entirely
        bytes_read_in = readbytesall!(io, buf, BUFFER_SIZE)
    end
    return bytes_read_in
end
function prepare_buffer!(io::NoopStream, buf::Vector{UInt8}, last_chunk_newline_at)
    bytes_read_in = prepare_buffer!(io.stream, buf, last_chunk_newline_at)
    TranscodingStreams.supplied!(io.state.buffer1, bytes_read_in)
    return bytes_read_in
end

# We process input data iteratively by populating a buffer from IO.
# In each iteration we first lex the newlines and then parse them in parallel.
# Assumption: we can find all valid endlines only by observing quotes (currently hardcoded to double quote)
#             and newline characters.
# TODO: '\n\r' currently produces 2 newlines... but we skip empty lines, so no biggie?
findmark(ptr, bytes_to_search, ::Val{B}) where B = UInt(something(memchr(ptr, bytes_to_search, B), 0))
function lex_newlines_in_buffer(io::IO, parsing_ctxfs::ParsingContext, options, byteset::Val{B}, bytes_to_search::UInt32, quoted::Bool=false) where B
    ptr = pointer(parsing_ctxfs.bytes) # We never resize the buffer, the array shouldn't need to relocate
    e, q = options.e, options.oq
    orig_bytes_to_search = bytes_to_search
    buf = parsing_ctxfs.bytes
    eols = parsing_ctxfs.eols
    # ScanByte.memchr only accepts UInt for the `len` argument, but we want to store our data in UInt32,
    # so we do a little conversion dance here to avoid converting the input on every iteration.
    _orig_bytes_to_search = UInt(orig_bytes_to_search)
    _bytes_to_search = UInt(bytes_to_search)

    offset = UInt32(0)
    while bytes_to_search > 0
        pos_to_check = findmark(ptr, _bytes_to_search, byteset)
        offset = UInt32(-_bytes_to_search + _orig_bytes_to_search + pos_to_check)
        if pos_to_check == 0
            length(eols) < 2 && !eof(io) && error("CSV parse job failed on lexing newlines. There was no linebreak in the entire buffer of $bytes_to_search bytes.")
            break
        else
            byte_to_check = @inbounds buf[offset]
            if quoted
                if byte_to_check == e && get(buf, offset+1, 0xFF) == q
                    pos_to_check += 1
                elseif byte_to_check == q
                    quoted = false
                end
            else
                if byte_to_check == q
                    quoted = true
                elseif byte_to_check != e
                    push!(eols, offset)
                end
            end
            ptr += pos_to_check
            _bytes_to_search -= pos_to_check
        end
    end

    if eof(io)
        quoted && error("CSV parse job failed on lexing newlines. There file has ended with an unmatched quote.")
        done = true
        # Insert a newline at the end of the file if there wasn't one
        # This is just to make `eols` contain both start and end `pos` of every single line
        @inbounds eols.elements[eols.occupied] != orig_bytes_to_search && push!(eols, orig_bytes_to_search + UInt32(1))
        last_chunk_newline_at = orig_bytes_to_search
    else
        done = false
        last_chunk_newline_at = @inbounds eols.elements[eols.occupied]
    end
    return last_chunk_newline_at, quoted, done
end
function lex_newlines_in_buffer(io::NoopStream, parsing_ctxfs::ParsingContext, options::Parsers.Options, byteset::Val{B}, bytes_to_search::UInt32, quoted::Bool=false) where B
    return lex_newlines_in_buffer(io.stream, parsing_ctxfs, options, byteset, bytes_to_search, quoted)
end


abstract type AbstractConsumeContext end
struct DebugContext <: AbstractConsumeContext; end
function consume!(taks_buf::TaskResultBuffer{N}, parsing_ctx::ParsingContext, row_num::UInt32, context::DebugContext) where {N}
    # @info taks_buf.cols[1].elements[1:5]
    # @info parsing_ctx.bytes[1:10]
    # @info parsing_ctx.eols
    return nothing
end

macro _parse_file_setup()
    esc(quote
        row_num = UInt32(1)
        done = false
        schema = parsing_ctx.schema
        result_bufs = [TaskResultBuffer{N}(schema) for _ in 1:Threads.nthreads()] # has to match the number of spawned tasks
    end)
end

macro _parse_rows_forloop()
    esc(quote
    @inbounds result_buf = result_bufs[task_id]
    empty!(result_buf)
    Base.ensureroom(result_buf, length(task)+1)
    for chunk_row_idx in 2:length(task)
        @inbounds prev_newline = task[chunk_row_idx - 1]
        @inbounds curr_newline = task[chunk_row_idx]
        (curr_newline - prev_newline) == 1 && continue # ignore empty lines
        # +1 -1 to exclude delimiters
        @inbounds row_bytes = view(buf, prev_newline+1:curr_newline-1)

        pos = 1
        len = length(row_bytes)
        code = Parsers.OK
        row_status = NoMissing
        column_indicators = zero(M)
        for col_idx in 1:N
            type = schema[col_idx]
            if Parsers.eof(code)
                row_status = TooFewColumnsError
                break # from column parsing (does this need to be a @goto?)
            end
            if type === Int
                (;val, tlen, code) = Parsers.xparse(Int, row_bytes, pos, len, options)::Parsers.Result{Int}
                unsafe_push!(getindex(result_buf.cols, col_idx)::BufferedVector{Int}, val)
            elseif type === Float64
                (;val, tlen, code) = Parsers.xparse(Float64, row_bytes, pos, len, options)::Parsers.Result{Float64}
                unsafe_push!(getindex(result_buf.cols, col_idx)::BufferedVector{Float64}, val)
            elseif type === String
                (;val, tlen, code) = Parsers.xparse(String, row_bytes, pos, len, options)::Parsers.Result{Parsers.PosLen}
                unsafe_push!(getindex(result_buf.cols, col_idx)::BufferedVector{Parsers.PosLen}, Parsers.PosLen(prev_newline+pos, val.len))
            else
                row_status = UnknownTypeError
                break # from column parsing (does this need to be a @goto?)
            end
            if Parsers.invalid(code)
                row_status = ValueParsingError
                break # from column parsing (does this need to be a @goto?)
            elseif Parsers.sentinel(code)
                row_status = HasMissing
                column_indicators |= M(1) << (col_idx - 1)
            end
            pos += tlen
        end # for col_idx
        if !Parsers.eof(code)
            row_status = TooManyColumnsError
        end
        unsafe_push!(result_buf.row_statuses, row_status)
        !iszero(column_indicators) && push!(result_buf.column_indicators, column_indicators) # No inbounds as we're growing this buffer lazily
    end # for row_idx
    end)
end

function _parse_file(io, parsing_ctx::ParsingContext, consume_ctx::AbstractConsumeContext, options::Parsers.Options, last_chunk_newline_at::UInt32, quoted::Bool, ::Val{N}, ::Val{M}, byteset::Val{B}) where {N,M,B}
    @_parse_file_setup
    while !done
        # Updates eols_buf with new newlines, byte buffer was updated either from initialization stage or at the end of the loop
        eols = parsing_ctx.eols[]
        # At most one task per thread (per iteration), fewer if not enough rows to warrant spawning extra tasks
        task_size = max(5_000, cld(length(eols), Threads.nthreads()))
        @sync for (task_id, task) = enumerate(Iterators.partition(eols, task_size))
            Threads.@spawn begin
                buf = $(parsing_ctx.bytes)
                @_parse_rows_forloop
                consume!(result_buf, $parsing_ctx, $row_num, consume_ctx) # Note we interpolated `row_num` to this task!
            end # @spawn
            row_num += UInt32(length(task))
        end #@sync
        empty!(parsing_ctx.eols)
        # We always end on a newline when processing a chunk, so we're inserting a dummy variable to
        # signal that. This works out even for the very first chunk.
        push!(parsing_ctx.eols, UInt32(0))
        bytes_read_in = prepare_buffer!(io, parsing_ctx.bytes, last_chunk_newline_at)
        (last_chunk_newline_at, quoted, done) = lex_newlines_in_buffer(io, parsing_ctx, options, byteset, bytes_read_in, quoted)
    end # while !done
end


function _parse_file_doublebuffer(io, parsing_ctx::ParsingContext, consume_ctx::AbstractConsumeContext, options::Parsers.Options, last_chunk_newline_at::UInt32, quoted::Bool, ::Val{N}, ::Val{M}, byteset::Val{B}) where {N,M,B}
    @_parse_file_setup
    # Updates eols_buf with new newlines, byte buffer was updated either from initialization stage or at the end of the loop
    parsing_ctx_next = ParsingContext(
        parsing_ctx.schema,
        parsing_ctx.header,
        Vector{UInt8}(undef, BUFFER_SIZE),
        BufferedVector{UInt32}(Vector{UInt32}(undef, parsing_ctx.eols.occupied), 0),
        parsing_ctx.limit,
    )
    while !done
        eols = parsing_ctx.eols[]
        # At most one task per thread (per iteration), fewer if not enough rows to warrant spawning extra tasks
        task_size = max(5_000, cld(length(eols), Threads.nthreads()))
        @sync begin
            @inbounds parsing_ctx_next.bytes[last_chunk_newline_at:end] .= parsing_ctx_next.bytes[last_chunk_newline_at:end]
            Threads.@spawn begin
                empty!(parsing_ctx_next.eols)
                push!(parsing_ctx_next.eols, UInt32(0))
                bytes_read_in = prepare_buffer!(io, parsing_ctx_next.bytes, last_chunk_newline_at)
                (last_chunk_newline_at, quoted, done) = lex_newlines_in_buffer(io, parsing_ctx_next, options, byteset, bytes_read_in, quoted)
            end
            for (task_id, task) = enumerate(Iterators.partition(eols, task_size))
                Threads.@spawn begin
                     # We have to interpolate the buffer into the task otherwise this allocates like crazy
                     # We interpolate here because interpolation doesn't work in nested macros (`@spawn @inbounds $buf` doesn't work)
                    buf = $(parsing_ctx.bytes)
                    @_parse_rows_forloop
                    consume!(result_buf, $parsing_ctx, $row_num, consume_ctx) # Note we interpolated `row_num` to this task!
                end # @spawn
                row_num += UInt32(length(task))
            end # for (task_id, task)
        end #@sync
        # TODO: does this allocate?
        parsing_ctx, parsing_ctx_next = parsing_ctx_next, parsing_ctx
    end # while !done
end

_input_to_io(input::IO) = input
function _input_to_io(input::String)
    io = NoopStream(open(input, "r"))
    TranscodingStreams.changemode!(io, :read)
    return io
end

function _create_options(delim::Char=',', quotechar::Char='"', escapechar::Char='"', sentinel::Union{Missing,String,Vector{String}}=missing, groupmark::Union{Char,UInt8,Nothing}=nothing, stripwhitespace::Bool=false)
    return Parsers.Options(
        sentinel=sentinel,
        wh1=delim ==  ' ' ? '\v' : ' ',
        wh2=delim == '\t' ? '\v' : '\t',
        openquotechar=UInt8(quotechar),
        closequotechar=UInt8(quotechar),
        escapechar=UInt8(escapechar),
        delim=UInt8(delim),
        quoted=true,
        ignoreemptylines=true,
        stripwhitespace=stripwhitespace,
        trues=["true", "1", "True", "t"],
        falses=["false", "0", "False", "f"],
        groupmark=groupmark,
    )
end

function hasBOM(bytes::Vector{UInt8})
    return @inbounds bytes[1] == 0xef && bytes[2] == 0xbb && bytes[3] == 0xbf
end

function parse_preamble!(io::IO, settings::ParserSettings, options::Parsers.Options, byteset::Val{B}) where {B}
    header_provided = !isnothing(settings.header)
    schema_provided = !isnothing(settings.schema)
    should_parse_header = settings.header_row != 0

    schema = DataType[]
    parsing_ctx = ParsingContext(
        schema,
        Symbol[],
        Vector{UInt8}(undef, BUFFER_SIZE),
        BufferedVector{UInt32}(),
        settings.limit,
    )
    # We always end on a newline when processing a chunk, so we're inserting a dummy variable to
    # signal that. This works out even for the very first chunk.
    !should_parse_header && push!(parsing_ctx.eols, UInt32(0))

    bytes_read_in = prepare_buffer!(io, parsing_ctx.bytes, UInt32(0)) # fill the buffer for the first time
    if bytes_read_in > 2 && hasBOM(parsing_ctx.bytes)
        bytes_read_in -= prepare_buffer!(io, parsing_ctx.bytes, UInt32(3)) - UInt32(3)
    end

    # lex the entire buffer for newlines
    (last_chunk_newline_at, quoted, done) = lex_newlines_in_buffer(io, parsing_ctx, options, byteset, bytes_read_in, false)

    @inbounds if schema_provided & header_provided
        append!(parsing_ctx.header, settings.header)
        append!(schema, settings.schema)
    elseif !schema_provided & header_provided
        append!(parsing_ctx.header, settings.header)
        resize!(schema, length(parsing_ctx.header))
        fill!(schema, String)
    elseif schema_provided & !header_provided
        append!(schema, settings.schema)
        if !should_parse_header
            for i in 1:length(settings.schema)
                push!(parsing_ctx.header, Symbol(string("COL_", i)))
            end
        else # should_parse_header
            eol = parsing_ctx.eols.elements[1] # 1 because we didn't preprend 0 eol to parsing_ctx.eols in this branch (should_parse_header)
            v = view(parsing_ctx.bytes, UInt32(1):eol)
            pos = 1
            code = Parsers.OK
            for i in 1:length(settings.schema)
                (;val, tlen, code) = Parsers.xparse(String, v, pos, length(v), options)
                !Parsers.ok(code) && error("Error parsing header for column $i at $(settings.header_row):$(pos).")
                @inbounds push!(parsing_ctx.header, Symbol(strip(String(v[val.pos:val.pos+val.len-1]))))
                pos += tlen
            end
            !(Parsers.eof(code) || Parsers.newline(code)) && error("Error parsing header, there are more columns that provided types in schema")
        end
    elseif should_parse_header
        #infer the number of columns from the first data row
        eol = parsing_ctx.eols.elements[1] # 1 because we didn't preprend 0 eol to parsing_ctx.eols in this branch (should_parse_header)
        v = view(parsing_ctx.bytes, UInt32(1):eol)
        pos = 1
        code = Parsers.OK
        i = 1
        while !(Parsers.eof(code) || Parsers.newline(code))
            (;val, tlen, code) = Parsers.xparse(String, v, pos, length(v), options)
            !Parsers.ok(code) && error("Error parsing header for column $i at $(settings.header_row):$(pos).")
            pos += tlen
            push!(parsing_ctx.header, Symbol(string("COL_", i)))
            i += 1
        end
        resize!(schema, length(parsing_ctx.header))
        fill!(schema, String)
    else
        #infer the number of columns from the header row
        eol = parsing_ctx.eols.elements[2] # 2 because we preprended 0 eol into parsing_ctx.eols in this branch (!should_parse_header)
        v = view(parsing_ctx.bytes, UInt32(1):eol)
        pos = 1
        code = Parsers.OK
        while !(Parsers.eof(code) || Parsers.newline(code))
            (;val, tlen, code) = Parsers.xparse(String, v, pos, length(v), options)
            !Parsers.ok(code) && error("Error parsing header for column $i at $(settings.header_row):$(pos).")
            @inbounds push!(parsing_ctx.header, Symbol(strip(String(v[val.pos:val.pos+val.len-1]))))
            pos += tlen
        end
        resize!(schema, length(parsing_ctx.header))
        fill!(schema, String)
    end

    return (parsing_ctx, last_chunk_newline_at, quoted, done)
end

function parse_file(
    input,
    schema::Union{Nothing,Vector{DataType}}=nothing,
    consume_ctx::AbstractConsumeContext=DebugContext();
    quotechar::Union{UInt8,Char}='"',
    delim::Union{UInt8,Char}=',',
    escapechar::Union{UInt8,Char}='"',
    header::Union{Nothing,Vector{Symbol}}=nothing,
    header_row::Integer=UInt32(0),
    skiprows::Integer=UInt32(0),
    limit::Integer=UInt32(0),
    doublebuffer::Bool=false,
)
    @assert header_row < 2 # else not implemented
    @assert skiprows == 0  # else not implemented
    @assert limit == 0     # else not implemented
    !isnothing(header) && !isnothing(schema) && length(header) != length(schema) && error("Provided header doesn't match the number of column of schema ($(length(header)) names, $(length(schema)) types).")

    io = _input_to_io(input)
    settings = ParserSettings(schema, header, UInt32(header_row), UInt32(skiprows), UInt32(limit))
    options = _create_options(delim, quotechar, escapechar)
    byteset = Val(ByteSet((UInt8(options.e), UInt8(options.oq), UInt8('\n'), UInt8('\r'))))
    (parsing_ctx, last_chunk_newline_at, quoted, done) = parse_preamble!(io, settings, options, Val(byteset))
    schema = parsing_ctx.schema

    if doublebuffer
        _parse_file_doublebuffer(io, parsing_ctx, consume_ctx, options, last_chunk_newline_at, quoted, Val(length(schema)), Val(_bounding_flag_type(length(schema))), Val(byteset))
    else
                     _parse_file(io, parsing_ctx, consume_ctx, options, last_chunk_newline_at, quoted, Val(length(schema)), Val(_bounding_flag_type(length(schema))), Val(byteset))
    end
    close(io)
    return nothing
end
