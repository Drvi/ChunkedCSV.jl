"""TaskResultBuffer accumulates results produced by a single task"""

@enum RowStatus::UInt8 NoMissing HasMissing TooFewColumnsError UnknownTypeError ValueParsingError TooManyColumnsError

struct TaskResultBuffer{N,M}
    cols::Vector{BufferedVector}
    row_statuses::BufferedVector{RowStatus}
    missings_flags::BufferedVector{M}
end

@inline _bounding_flag_type(N) = N > 128 ? BitSet :
    N > 64 ? UInt128 :
    N > 32 ? UInt64 :
    N > 16 ? UInt32 :
    N > 8 ? UInt16 : UInt8
_translate_to_buffer_type(T::DataType) = T === String ? Parsers.PosLen : T

TaskResultBuffer(schema) = TaskResultBuffer{length(schema)}(schema)
TaskResultBuffer{N}(schema::Vector{DataType}) where N = TaskResultBuffer{N, _bounding_flag_type(N)}(
    [BufferedVector{_translate_to_buffer_type(schema[i])}() for i in 1:N],
    BufferedVector{RowStatus}(),
    BufferedVector{_bounding_flag_type(N)}(),
)

# Prealocate BufferedVectors with `n` values
TaskResultBuffer(schema, n) = TaskResultBuffer{length(schema)}(schema, n)
TaskResultBuffer{N}(schema::Vector{DataType}, n::Int) where N = TaskResultBuffer{N, _bounding_flag_type(N)}(
    [BufferedVector{schema[i]}(Vector{_translate_to_buffer_type(schema[i])}(undef, n), 0) for i in 1:N],
    BufferedVector{RowStatus}(Vector{RowStatus}(undef, n), 0),
    BufferedVector{_bounding_flag_type(N)}(),
)

function Base.empty!(buf::TaskResultBuffer)
    foreach(empty!, buf.cols)
    empty!(buf.row_statuses)
    empty!(buf.missings_flags)
end