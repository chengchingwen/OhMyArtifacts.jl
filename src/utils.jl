## utilities ##

pkgversion(m::Module) = _pkgversion(joinpath(dirname(string(first(methods(Base.moduleroot(m).eval)).file)), "..", "Project.toml"))
pkgversion(::Nothing) = _pkgversion(Scratch.ignore_eacces(()->Base.active_project()))
function pkgversion(uuid::Base.UUID)
    pkg = findfirst(o->o[1].uuid == uuid, Iterators.map(identity, Base.pkgorigins))
    if pkg !== nothing
        pkgorigin = Base.pkgorigins[pkg]
        return _pkgversion(joinpath(dirname(pkgorigin.path), "..", "Project.toml"))
    end
    return nothing
end

function _pkgversion(project)
    if project !== nothing && isfile(project)
        toml = Pkg.TOML.parsefile(project)
        haskey(toml, "version") && return Base.VersionNumber(toml["version"])
    end
    return nothing
end

# create pid lock at the same place of the given file
create_file_lock(file, lock_name) = mkpidlock(joinpath(dirname(file), lock_name))
create_file_lock(f::Function, file, lock_name) = mkpidlock(f, joinpath(dirname(file), lock_name))

# Get the modification time in UTC.
function modified_time(file)
    return Dates.unix2datetime(mtime(file)) + round(now() - now(Dates.UTC), Hour)
end

# merge nested Dict
_merge(d::AbstractDict...) = mergewith(_merge, d...)
_merge(d::DateTime...) = min(d...)
merge_toml(d...) = mergewith(_merge, d...)
merge_toml!(d...) = mergewith!(_merge, d...)

function write_toml(file, toml)
    open(file, "w") do io
        TOML.print(io, toml, sorted=true)
    end
end

# recursively walk through the dir and find all files
readdirfiles(dir) = readdirdepth(Base.Fix2(isa, Int), dir; files_only=true)

# readdir depends on the depth
function readdirdepth(f, dir; files_only=false, dirs_only=false)
    @assert nand(files_only, dirs_only) "files_only and dirs_only cannot both be true"
    p = length(dir) + !isdirpath(dir)
    s = String[]
    for (root, dirs, files) in walkdir(dir)
        relroot = chop(root, head=p, tail=0)
        paths = splitpath(relroot)
        ".git" in paths && continue
        depth = isempty(relroot) ? 0 : length(paths)
        if f(depth)
            dirs_only || append!(s, Iterators.map(Base.Fix1(joinpath, root), files))
            files_only || append!(s, Iterators.map(Base.Fix1(joinpath, root), dirs))
        end
    end
    return s
end

@static if VERSION < v"1.7"
    nand(x...) = ~(&)(x...)
end

## SHA256 ##

struct SHA256
    bytes::NTuple{32, UInt8}
end

function SHA256(bytes::Vector{UInt8})
    length(bytes) == 32 ||
        throw(ArgumentError("wrong number of bytes for SHA256 hash: $(length(bytes))"))
    return SHA256(ntuple(i->bytes[i], Val(32)))
end
SHA256(s::AbstractString) = SHA256(hex2bytes(s))
Base.parse(::Type{SHA256}, s::AbstractString) = SHA256(s)
function Base.tryparse(::Type{SHA256}, s::AbstractString)
    try
        return parse(SHA256, s)
    catch e
        if isa(e, ArgumentError)
            return nothing
        end
        rethrow(e)
    end
end

Base.string(hash::SHA256) = bytes2hex(hash.bytes)
Base.print(io::IO, hash::SHA256) = bytes2hex(io, hash.bytes)
Base.show(io::IO, hash::SHA256) = print(io, "SHA256(\"", hash, "\")")

Base.isless(a::SHA256, b::SHA256) = isless(a.bytes, b.bytes)
Base.hash(a::SHA256, h::UInt) = hash((SHA256, a.bytes), h)
Base.:(==)(a::SHA256, b::SHA256) = a.bytes == b.bytes
