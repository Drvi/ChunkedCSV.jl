struct _GuessDateTime <: Dates.TimeType; x::Dates.DateTime  end
_GuessDateTime(vals...) = _GuessDateTime(DateTime(vals...))
Base.convert(::Type{DateTime}, x::_GuessDateTime) = x.x
Base.convert(::Type{_GuessDateTime}, x::DateTime) = _GuessDateTime(x)

Dates.default_format(::Type{_GuessDateTime}) = Dates.default_format(Dates.DateTime)
Parsers.default_format(::Type{_GuessDateTime}) = Parsers.default_format(Dates.DateTime)
Dates.validargs(::Type{_GuessDateTime}, vals...) = Dates.validargs(Dates.DateTime, vals...)

# [y]yyy-[m]m-[d]d(T|\s)HH:MM:SS(\.s{1,3}})?(zzzz|ZZZ|\Z)?
Base.@propagate_inbounds function _default_tryparse_timestamp(buf, pos, len, code, b, options)
    # ensure there is enough room for at least yyyy-mm-dd
    len - pos < 9 && (return DateTime(0), code | Parsers.INVALID | Parsers.EOF, len)
    year = 0
    for i in 1:4
        b -= 0x30
        b > 0x09 && (return DateTime(0), code | Parsers.INVALID, pos)
        year = Int(b) + 10 * year
        b = buf[pos += 1]
        (i > 2 && b == UInt8('-')) && break
    end
    code |= Parsers.OK
    b != UInt8('-')  && (return DateTime(year), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    month = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return DateTime(year), code | Parsers.INVALID, pos)
        month = Int(b) + 10 * month
        b = buf[pos += 1]
        b == UInt8('-') && break
    end
    month > 12 && (return DateTime(year), code | Parsers.INVALID, pos)
    b != UInt8('-')  && (return DateTime(year, month), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    day = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return DateTime(year, month), code | Parsers.INVALID, pos)
        day = Int(b) + 10 * day
        pos == len && (code |= Parsers.EOF; break)
        b = buf[pos += 1]
        (b == UInt8('T') ||  b == UInt8(' ')) && break
    end
    day > Dates.daysinmonth(year, month) && (return DateTime(year, month), code | Parsers.INVALID, pos)
    (pos == len || (b != UInt8('T') && b != UInt8(' '))) && (return DateTime(year, month, day), code | Parsers.OK, pos)
    # ensure there is enough room for at least HH:MM:DD
    len - pos < 8 && (return DateTime(0), code | Parsers.INVALID | Parsers.EOF, len)
    b = buf[pos += 1]

    hour = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return DateTime(year, month, day), code | Parsers.INVALID, pos)
        hour = Int(b) + 10 * hour
        b = buf[pos += 1]
    end
    hour > 24 && (return DateTime(year, month, day), code | Parsers.INVALID, pos)
    b != UInt8(':') && (return DateTime(year, month, day, hour), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    minute = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return DateTime(year, month, day, hour), code | Parsers.INVALID, pos)
        minute = Int(b) + 10 * minute
        b = buf[pos += 1]
    end
    minute > 60 && (return DateTime(year, month, day, hour), code | Parsers.INVALID, pos)
    b != UInt8(':') && (return DateTime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    second = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return DateTime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
        second = Int(b) + 10 * second
        pos == len && break
        b = buf[pos += 1]
    end
    pos == len && (code |= Parsers.EOF)
    second > 60 && (return DateTime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
    if (pos == len || b == options.delim.token || b == options.cq.token)
        code |= isnothing(Dates.validargs(DateTime, year, month, day, hour, minute, second, 0)) ? Parsers.OK : Parsers.INVALID
        return DateTime(year, month, day, hour, minute, second), code, pos
    end

    millisecond = 0
    if b == UInt8('.')
        i = 0
        while pos < len && ((b = (buf[pos += 1] - 0x30)) <= 0x09)
            millisecond = Int(b) + 10 * millisecond
            i += 1
        end
        # TODO: rounding modes like we do for FixedPointDecimals
        i == 0 || millisecond > 999 && (return DateTime(year, month, day, hour, minute, second), code | Parsers.INVALID, pos)
        if (pos == len || (b + 0x30) == options.delim.token || b == options.cq.token)
            pos == len && (code |= Parsers.EOF)
            code |= isnothing(Dates.validargs(DateTime, year, month, day, hour, minute, second, millisecond)) ? Parsers.OK : Parsers.INVALID
            return DateTime(year, month, day, hour, minute, second, millisecond), code, pos
        end
        b += 0x30
    end
    b == UInt8(' ') && pos < len && (b = buf[pos += 1])
    if b == UInt8('z') || b == UInt8('Z')
        tz = "Z"
        pos == len ? (code |= Parsers.EOF) : (pos += 1)
    elseif b == UInt('+') || b == UInt8('-')
        tz, pos, b, code = Parsers.tryparsenext(Dates.DatePart{'z'}(4, false), buf, pos, len, b, code)
    else
        tz, pos, b, code = Parsers.tryparsenext(Dates.DatePart{'Z'}(3, false), buf, pos, len, b, code)
    end
    Parsers.invalid(code) && (return DateTime(year, month, day, hour, minute, second, millisecond), code , pos)
    if isnothing(Dates.validargs(ZonedDateTime, year, month, day, hour, minute, second, millisecond, tz))
        ztd = TimeZones.ZonedDateTime(year, month, day, hour, minute, second, millisecond, tz)
        return (Dates.DateTime(ztd, TimeZones.UTC), code | Parsers.OK, pos)
    else
        return (Dates.DateTime(year, month, day, hour, minute, second, millisecond), code | Parsers.INVALID, pos)
    end
end


function Parsers.typeparser(::Type{_GuessDateTime}, source::AbstractVector{UInt8}, pos, len, b, code, pl, options)
    if isnothing(options.dateformat)
        (x, code, pos) = @inbounds _default_tryparse_timestamp(source, pos, len, code, b, options)
        return (pos, code, Parsers.PosLen(pl.pos, pos - pl.pos), x)
    else
        return Parsers.typeparser(Dates.DateTime, source, pos, len, b, code, pl, options)
    end
end
