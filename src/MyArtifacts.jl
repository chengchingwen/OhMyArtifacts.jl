module MyArtifacts

using Pkg
using Pkg.Artifacts
using Pkg.Types: parse_toml, write_env_usage
using SHA
using Dates
using Printf
using TOML
using Scratch
using Pidfile

const SCRATCH_DIR = Ref{String}()
const ARTIFACTS_DIR = Ref{String}()

const ARTIFACTS_TOML_VAR_SYM = Ref{Symbol}(:my_artifacts)

function __init__()
    global SCRATCH_DIR, ARTIFACTS_DIR
    # create scratch space
    ARTIFACTS_DIR[] = @get_scratch!("artifacts")
    SCRATCH_DIR[] = dirname(ARTIFACTS_DIR[])

    orphan_file = orphanages_toml_path()
    last_gc_time = if isfile(orphan_file)
        modified_time(orphan_file)
    else
        orphanages_toml()
        now()
    end
    if now() - last_gc_time >= Day(7)
        find_orphanages()
    end

    return
end

export my_artifacts_toml!, @my_artifacts_toml!, create_my_artifact, bind_my_artifact!,
    my_artifact_hash, my_artifact_path, my_artifact_exists,
    @my_artifact


"""
    my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})

Return the path to (or creates) "Artifacts.toml" for the given `pkg`.

See also: [`@my_artifacts_toml!`](@ref)
"""
function my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})
    uuid = Scratch.find_uuid(pkg)
    path = get_scratch!(@__MODULE__, string(uuid), pkg)
    return touch(joinpath(path, "Artifacts.toml"))
end


## utilities

function get_scratch_dir()
    global SCRATCH_DIR
    return SCRATCH_DIR[]
end

function get_artifacts_dir()
    global ARTIFACTS_DIR
    return ARTIFACTS_DIR[]
end

function get_artifacts_toml_sym()
    global ARTIFACTS_TOML_VAR_SYM
    return ARTIFACTS_TOML_VAR_SYM[]
end

orphanages_toml_path() = joinpath(get_scratch_dir(), "my_artifact_orphanages.toml")

function orphanages_toml()
    path = orphanages_toml_path()
    mkpath(dirname(path))
    touch(path)
end

function usages_toml()
    path = joinpath(get_scratch_dir(), "my_artifact_usage.toml")
    mkpath(dirname(path))
    touch(path)
end

function modified_time(file)
    return Dates.unix2datetime(mtime(file)) + round(now() - now(Dates.UTC), Hour)
end

## macros

"""
    @my_artifacts_toml!()

Convenience macro that gets/creates a "Artifacts.toml" and parented to the package the calling module belongs to.

See also: [`my_artifacts_toml!`](@ref)
"""
macro my_artifacts_toml!()
    uuid = Base.PkgId(__module__).uuid
    return quote
        my_artifacts_toml!($(esc(uuid)))
    end
end

function cached_my_artifact_toml_path(mod::Module)
    sym = get_artifacts_toml_sym()
    !isdefined(mod, sym) && return nothing
    path = getfield(mod, sym)
    return (path isa Ref ? path[] : path)::String
end

function cached_my_artifact_toml_expr(mod::Module)
    sym = get_artifacts_toml_sym()
    !isdefined(mod, sym) && return nothing
    return quote
        path = getfield($mod, $(QuoteNode(sym)))
        (path isa Ref ? path[] : path)::String
    end
end

"""
    @my_artifact op name [hash]

Convenient macro for working with "Artifacts.toml". Requiring a global variable `my_artifacts` storing the path
 to "Artifacts.toml" (created by `@my_artifacts_toml!`) to work correctly.

Usage:

1. `@my_artifact :bind name hash` => `bind_my_artifact!(my_artifacts, name, hash)`
2. `@my_artifact :hash name` => `my_artifact_hash(name, my_artifacts)`
3. `@my_artifact :unbind name` => `unbind_my_artifact!(my_artifacts, name)`

See also: [`bind_my_artifact!`](@ref), [`my_artifact_hash`](@ref),
 [`unbind_my_artifact!`](@ref), [`@my_artifacts_toml`](@ref)
"""
macro my_artifact(op, name, ex...)
    toml_path = cached_my_artifact_toml_expr(__module__)
    if isnothing(toml_path)
        error("no cached path for my artifact toml: $(__module__).$(get_artifacts_toml_sym()) undefined.")
    end

    if op == :bind || op == :(:bind)
        !isone(length(ex)) && error("wrong number of arguments for :bind, need \$name and \$hash.")
        hash = ex[1]
        return :(bind_my_artifact!($(toml_path), $(esc(name)), $(esc(hash))))
    elseif op == :hash || op == :(:hash)
        !iszero(length(ex)) && error("wrong number of arguments for :hash, need \$name.")
        return :(my_artifact_hash($(esc(name)), $(toml_path)))
    elseif op == :unbind || op == :(:unbind)
        !iszero(length(ex)) && error("wrong number of arguments for :unbind, need \$name.")
        return :(unbind_my_artifact!($(toml_path), $(esc(name))))
    else
        error("unknown artifact op: $op")
    end
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

## artifacts ##

function load_my_artifacts_toml(artifacts_toml::String)
    artifact_dict = mkpidlock(joinpath(dirname(artifacts_toml), "artifact_lock")) do
        parse_toml(artifacts_toml)
    end
    return artifact_dict
end

"""
    my_artifact_hash(name::String, artifacts_toml::String)

Return the hash found in `artifacts_toml` with given `name`, or `nothing` if not found.
"""
function my_artifact_hash(name::String, artifacts_toml::String)
    artifact_dict = load_my_artifacts_toml(artifacts_toml)
    if haskey(artifact_dict, name)
        return SHA256(artifact_dict[name]["sha256"])
    else
        return nothing
    end
end

"""
    my_artifact_path(hash::SHA256)

Given an artifact (identified by SHA256 content hash), return its installation path. If the artifact does not exist,
 returns the location it would be installed to.

See also: [`my_artifact_exists`](@ref)
"""
function my_artifact_path(hash::SHA256)
    artifacts_dir = get_artifacts_dir()
    return joinpath(artifacts_dir, string(hash))
end

"""
    my_artifact_exists(hash::SHA256)

Returns whether or not the given artifact (identified by its SHA256 content hash) exists on-disk.
"""
function my_artifact_exists(hash::SHA256)
    return isfile(my_artifact_path(hash))
end

"""
    create_my_artifact(f::Function)

Creates a new artifact by doing `path = f(working_dir)`, hashing the returned `path`, and moving it to
 the artifact store. Returns the identifying hash of this artifact.

`f(working_dir)` should return an absolute path to a single file at the top level of `working_dir`.
"""
function create_my_artifact(f::Function)
    artifacts_dir = get_artifacts_dir()
    temp_dir = mktempdir(artifacts_dir)

    try
        # create file in temp dir
        filepath = f(temp_dir)

        # make sure the returned file path is correct
        !isabspath(filepath) && error("returned file path $filepath is not a abspath")
        !startswith(filepath, temp_dir) && error("returned file path $filepath result outside of the given dir")

        file = basename(filepath)
        filepath = joinpath(temp_dir, file)
        !isfile(filepath) && error("returned file is not at the top level of given dir")

        # calculate the file hash
        artifact_hash = SHA256(Pkg.GitTools.blob_hash(SHA.SHA256_CTX, filepath))
        new_path = joinpath(artifacts_dir, string(artifact_hash))

        # skip if file already exist
        filelock = mkpidlock(joinpath(dirname(new_path), "$(string(artifact_hash)).lock"))
        try
            if !isfile(new_path)
                mv(filepath, new_path)
                fmode = filemode(new_path)
                # read-only
                chmod(new_path, fmode & (typemax(fmode) ⊻ 0o222))
            end
        finally
            close(filelock)
        end

        return artifact_hash
    finally
        rm(temp_dir; recursive=true, force=true)
    end
end

"""
    bind_my_artifact!(artifacts_toml::String, name::String, hash::SHA256; force::Bool = false)

Writes a mapping of `name` -> `hash` within the given "Artifacts.toml" file. If `force` is set to `true`,
 this will overwrite a pre-existant mapping, otherwise an error is raised.
"""
function bind_my_artifact!(artifacts_toml::String, name::String, hash::SHA256; force::Bool = false)
    artifact_lock = mkpidlock(joinpath(dirname(artifacts_toml), "artifact_lock"))
    try
        artifact_dict = parse_toml(artifacts_toml)

        if !force && haskey(artifact_dict, name)
            error("Mapping for $name within $(artifacts_toml) already exists!")
        end

        meta =  Dict{String,Any}(
            "sha256" => string(hash),
        )

        artifact_dict[name] = meta
        let artifact_dict = artifact_dict
            open(artifacts_toml, "w") do io
                TOML.print(io, artifact_dict, sorted=true)
            end
        end
    finally
        close(artifact_lock)
    end

    track_my_artifacts(artifacts_toml, name, hash)
    return
end

function track_my_artifacts(artifacts_toml::String, name::String, hash::SHA256)
    artifacts_dir = get_artifacts_dir()

    usage_file = usages_toml()
    mkpath(dirname(usage_file))

    artifact_path = joinpath(artifacts_dir, string(hash))

    usage_lock = mkpidlock(joinpath(dirname(usage_file), ".my_artifact_usage_lock"))
    try
        usage_toml = if isfile(usage_file)
            parse_toml(usage_file)
        else
            Dict{String, Any}()
        end

        if haskey(usage_toml, artifact_path)
            usage_toml[artifact_path][artifacts_toml][name] = now()
        else
            usage_dict = Dict{String, Any}(
                artifacts_toml => Dict{String, Any}(
                    name => now()
                )
            )
            usage_toml[artifact_path] = usage_dict
        end

        let usage_toml = usage_toml
            open(usage_file, "w") do io
                TOML.print(io, usage_toml, sorted=true)
            end
        end
    finally
        close(usage_lock)
    end
    return
end

"""
    unbind_my_artifact!(artifacts_toml::String, name::String)

Unbind the given `name` from the "Artifacts.toml" file. Silently fails if no such binding exists within the file.
"""
function unbind_my_artifact!(artifacts_toml::String, name::String)
    artifact_lock = mkpidlock(joinpath(dirname(artifacts_toml), "artifact_lock"))
    try
        artifact_dict = parse_toml(artifacts_toml)

        !haskey(artifact_dict, name) && return

        hash = artifact_dict[name]["sha256"]

        delete!(artifact_dict, name)

        let artifact_dict = artifact_dict
            open(artifacts_toml, "w") do io
                TOML.print(io, artifact_dict, sorted=true)
            end
        end
    finally
        close(artifact_lock)
    end
    return
end

function find_orphanages(; collect_delay::Period=Day(7))
    artifacts_dir = get_artifacts_dir()

    usage_file = usages_toml()
    orphanage_file = orphanages_toml()

    !isfile(usage_file) && return

    usage_lock = mkpidlock(joinpath(dirname(usage_file), ".my_artifact_usage_lock"))
    try
        usage_toml = if isfile(usage_file)
            parse_toml(usage_file)
        else
            Dict{String, Any}()
        end

        # find orphan artifacts
        orphanage = Pair{String, DateTime}[]

        # artifact without binding
        for artifact_path in readdir(MyArtifacts.get_artifacts_dir(), join=true)
            if !haskey(usage_toml, artifact_path)
                push!(orphanage, artifact_path=>modified_time(artifact_path))
            end
        end

        # artifact with binding
        curr_gc_time = now()
        for (artifact_path, usage_dict) in usage_toml
            # check if all bindings are removed

            for (artifacts_toml, entrys) in usage_dict
                if !isfile(artifacts_toml)
                    # the toml is already removed, so no such usage exist
                    delete!(usage_dict, artifacts_toml)
                else
                    # else we read the toml
                    artifact_dict = load_my_artifacts_toml(artifacts_toml)

                    # check that all usage entry is still exist, or remove them
                    for entry in keys(entrys)
                        if !haskey(artifact_dict, entry)
                            delete!(entrys, entry)
                        end
                    end

                    # if no entrys, remove this usage
                    isempty(entrys) && delete!(usage_dict, artifacts_toml)
                end
            end

            if isempty(usage_dict)
                # no usage of this artifact exist
                # mark it as orphan and record the current time
                push!(orphanage, artifact_path=>curr_gc_time)
                delete!(usage_toml, artifact_path)
            end
        end

        # update usage toml
        let usage_toml = usage_toml
            open(usage_file, "w") do io
                TOML.print(io, usage_toml, sorted=true)
            end
        end

        # update the orphanage file
        old_orphans = if isfile(orphanage_file)
            parse_toml(orphanage_file)
        else
            Dict{String, DateTime}()
        end
        # merge old and new orphan list
        # *notice*: if the entry already on the list, keep the old recorded time
        new_orphans = merge(Dict(orphanage), old_orphans)

        # mark orphanage for deletion
        gc_time = now()
        deletion_list = String[]
        for artifact_path in keys(new_orphans)
            last_gc_time = new_orphans[artifact_path]
            if gc_time - last_gc_time >= collect_delay
                push!(deletion_list, artifact_path)
                delete!(new_orphans, artifact_path)
            end
        end

        # update the resulted orphanage to file
        let new_orphans = new_orphans
            open(orphanage_file, "w") do io
                TOML.print(io, new_orphans, sorted=true)
            end
        end

        # delete my artifacts
        pretty_byte_str = (size) -> begin
            bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
            return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
        end

        function file_size(path)
            size = try
                lstat(path).size
            catch ex
                @error("Failed to calculate size of $path", exception=ex)
            end
            return size
        end

        function delete_path(path)
            path_size = file_size(path)
            try
                Base.Filesystem.prepare_for_deletion(path)
                Base.rm(path; recursive=true, force=true)
            catch e
                @warn("Failed to delete $path", exception=e)
                return 0
            end
            return path_size
        end

        space_freed = 0
        for artifact_path in deletion_list
            space_freed += delete_path(artifact_path)
        end

        ndel = length(deletion_list)
        if ndel > 0
            s = ndel == 1 ? "" : "s"
            @info "$ndel MyArtifact$(s) deleted ($(pretty_byte_str(space_freed)))"
        end

    finally
        close(usage_lock)
    end
    return
end


end
