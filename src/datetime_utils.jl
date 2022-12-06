struct _GuessDateTime <: Dates.TimeType; x::Dates.DateTime  end
_GuessDateTime(vals...) = _GuessDateTime(DateTime(vals...))
Base.convert(::Type{DateTime}, x::_GuessDateTime) = x.x
Base.convert(::Type{_GuessDateTime}, x::DateTime) = _GuessDateTime(x)

Dates.default_format(::Type{_GuessDateTime}) = Dates.default_format(Dates.DateTime)
Parsers.default_format(::Type{_GuessDateTime}) = Parsers.default_format(Dates.DateTime)
Dates.validargs(::Type{_GuessDateTime}, vals...) = Dates.validargs(Dates.DateTime, vals...)

function _unsafe_datetime(y=0, m=1, d=1, h=0, mi=0, s=0, ms=0)
    rata = ms + 1000 * (s + 60mi + 3600h + 86400 * Dates.totaldays(y, m, d))
    return DateTime(Dates.UTM(rata))
end

# [y]yyy-[m]m-[d]d(T|\s)HH:MM:SS(\.s{1,3}})?(zzzz|ZZZ|\Z)?
Base.@propagate_inbounds function _default_tryparse_timestamp(buf, pos, len, code, b, options)
    # ensure there is enough room for at least yyyy-mm-dd
    len - pos < 9 && (return _unsafe_datetime(0), code | Parsers.INVALID | Parsers.EOF, len)
    year = 0
    for i in 1:4
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(0), code | Parsers.INVALID, pos)
        year = Int(b) + 10 * year
        b = buf[pos += 1]
        (i > 2 && b == UInt8('-')) && break
    end
    b != UInt8('-')  && (return _unsafe_datetime(year), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    month = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(year), code | Parsers.INVALID, pos)
        month = Int(b) + 10 * month
        b = buf[pos += 1]
        b == UInt8('-') && break
    end
    month > 12 && (return _unsafe_datetime(year), code | Parsers.INVALID, pos)
    b != UInt8('-')  && (return _unsafe_datetime(year, month), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    day = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(year, month), code | Parsers.INVALID, pos)
        day = Int(b) + 10 * day
        pos == len && (code |= Parsers.EOF; break)
        b = buf[pos += 1]
        (b == UInt8('T') ||  b == UInt8(' ')) && break
    end
    day > Dates.daysinmonth(year, month) && (return _unsafe_datetime(year, month), code | Parsers.INVALID, pos)
    (pos == len || (b != UInt8('T') && b != UInt8(' '))) && (return _unsafe_datetime(year, month, day), code | Parsers.OK, pos)
    # ensure there is enough room for at least HH:MM:DD
    len - pos < 8 && (return _unsafe_datetime(0), code | Parsers.INVALID | Parsers.EOF, len)
    b = buf[pos += 1]

    hour = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(year, month, day), code | Parsers.INVALID, pos)
        hour = Int(b) + 10 * hour
        b = buf[pos += 1]
    end
    hour > 24 && (return _unsafe_datetime(year, month, day), code | Parsers.INVALID, pos)
    b != UInt8(':') && (return _unsafe_datetime(year, month, day, hour), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    minute = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(year, month, day, hour), code | Parsers.INVALID, pos)
        minute = Int(b) + 10 * minute
        b = buf[pos += 1]
    end
    minute > 60 && (return _unsafe_datetime(year, month, day, hour), code | Parsers.INVALID, pos)
    b != UInt8(':') && (return _unsafe_datetime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
    b = buf[pos += 1]

    second = 0
    for _ in 1:2
        b -= 0x30
        b > 0x09 && (return _unsafe_datetime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
        second = Int(b) + 10 * second
        pos == len && break
        b = buf[pos += 1]
    end
    pos == len && (code |= Parsers.EOF)
    second > 60 && (return _unsafe_datetime(year, month, day, hour, minute), code | Parsers.INVALID, pos)
    if (pos == len || b == options.delim.token || b == options.cq.token)
        code |= isnothing(Dates.validargs(DateTime, year, month, day, hour, minute, second, 0)) ? Parsers.OK : Parsers.INVALID
        if Parsers.ok(code)
            return _unsafe_datetime(year, month, day, hour, minute, second), code, pos
        else
            return _unsafe_datetime(0), code, pos
        end
    end

    millisecond = 0
    if b == UInt8('.')
        i = 0
        while pos < len && ((b = (buf[pos += 1] - 0x30)) <= 0x09)
            millisecond = Int(b) + 10 * millisecond
            i += 1
        end
        # TODO: rounding modes like we do for FixedPointDecimals
        i == 0 || millisecond > 999 && (return _unsafe_datetime(year, month, day, hour, minute, second), code | Parsers.INVALID, pos)
        if (pos == len || (b + 0x30) == options.delim.token || b == options.cq.token)
            pos == len && (code |= Parsers.EOF)
            code |= isnothing(Dates.validargs(DateTime, year, month, day, hour, minute, second, millisecond)) ? Parsers.OK : Parsers.INVALID
            if Parsers.ok(code)
                return _unsafe_datetime(year, month, day, hour, minute, second, millisecond), code, pos
            else
                return _unsafe_datetime(0), code, pos
            end
        end
        b += 0x30
    elseif pos == len
        return (_unsafe_datetime(year, month, day, hour, minute, second, millisecond), code | Parsers.OK, pos)
    end
    b == UInt8(' ') && pos < len && (b = buf[pos += 1])
    tz, pos, b, code = _tryparse_timezone(buf, pos, b, len, code)
    Parsers.invalid(code) && (return _unsafe_datetime(year, month, day, hour, minute, second, millisecond), code , pos)
    if isnothing(Dates.validargs(ZonedDateTime, year, month, day, hour, minute, second, millisecond, tz))
        code |= Parsers.OK
        if tz === _Z
            # Avoiding TimeZones.ZonedDateTime to save some allocations in case the `tz`
            # corresponds to a UTC time zone.
            return (_unsafe_datetime(year, month, day, hour, minute, second, millisecond), code, pos)
        else
            dt = _unsafe_datetime(year, month, day, hour, minute, second, millisecond)
            ztd = TimeZones.ZonedDateTime(dt, TimeZones.TimeZone(tz))
            return (Dates.DateTime(ztd, TimeZones.UTC), code, pos)
        end
    else
        return (Dates._unsafe_datetime(0), code | Parsers.INVALID, pos)
    end
end

# To avoid allocating a string, we reuse this constant for all UTC equivalent timezones
# (SubString is what we get from Parsers.tryparsenext when parsing timezones)
# This is needed until https://github.com/JuliaTime/TimeZones.jl/issues/271 is fixed
const _Z = SubString("Z", 1:1)
@inline function _tryparse_timezone(buf, pos, b, len, code)
    @inbounds if b == UInt8('+') || b == UInt8('-')
        if len - pos < 2
        elseif buf[pos+1] == UInt8('0')
            if buf[pos+2] == UInt8('0')
                if len - pos < 4
                elseif buf[pos+3] == UInt8(':')
                    if len - pos < 5
                    elseif buf[pos+4] == UInt8('0')
                        if buf[pos+5] == UInt8('0')
                            return _Z, pos+5, UInt8('0'), code
                        end
                    end
                elseif buf[pos+3] == UInt8('0')
                    if buf[pos+4] == UInt8('0')
                        return _Z, pos+4, UInt8('0'), code
                    end
                end
            end
        end
        return Parsers.tryparsenext(Dates.DatePart{'z'}(4, false), buf, pos, len, b, code)
    end

    @inbounds if b == UInt8('G')
        if len - pos < 3
        elseif buf[pos+1] == UInt8('M')
            if buf[pos+2] == UInt8('T')
                return (_Z, pos+3, UInt8('T'), code)
            end
        end
    elseif b == UInt8('z') || b == UInt8('Z')
        return (_Z, pos+1, b, code)
    elseif b == UInt8('U')
        if len - pos < 3
        elseif buf[pos+1] == UInt8('T')
            if buf[pos+2] == UInt8('C')
                return (_Z, pos+3, UInt8('C'), code)
            end
        end
    end
    return Parsers.tryparsenext(Dates.DatePart{'Z'}(3, false), buf, pos, len, b, code)
end

function Parsers.typeparser(::Type{_GuessDateTime}, source::AbstractVector{UInt8}, pos, len, b, code, pl, options)
    if isnothing(options.dateformat)
        (x, code, pos) = @inbounds _default_tryparse_timestamp(source, pos, len, code, b, options)
        return (pos, code, Parsers.PosLen(pl.pos, pos - pl.pos), x)
    else
        return Parsers.typeparser(Dates.DateTime, source, pos, len, b, code, pl, options)
    end
end
