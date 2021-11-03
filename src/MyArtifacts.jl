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

function get_scratch_dir()
    global SCRATCH_DIR
    return SCRATCH_DIR[]
end

function get_artifacts_dir()
    global ARTIFACTS_DIR
    return ARTIFACTS_DIR[]
end

function __init__()
    global SCRATCH_DIR, ARTIFACTS_DIR
    # create scratch space
    ARTIFACTS_DIR[] = @get_scratch!("artifacts")
    SCRATCH_DIR[] = dirname(ARTIFACTS_DIR[])

    find_orphanages()
    return
end

export my_artifacts_toml!, create_my_artifact, bind_my_artifact!,
    my_artifact_hash, my_artifact_path, my_artifact_exists

function my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})
    uuid = Scratch.find_uuid(pkg)
    path = get_scratch!(@__MODULE__, string(uuid), pkg)
    return touch(joinpath(path, "Artifacts.toml"))
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

function my_artifact_hash(name::String, artifacts_toml::String)
    artifact_dict = load_my_artifacts_toml(artifacts_toml)
    if haskey(artifact_dict, name)
        return artifact_dict[name]["sha256"]
    else
        return nothing
    end
end

function my_artifact_path(hash::SHA256)
    artifacts_dir = get_artifacts_dir()
    return joinpath(artifacts_dir, string(hash))
end

function my_artifact_exists(hash::SHA256)
    return isfile(my_artifact_path(hash))
end

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
        if !isfile(new_path)
            mv(filepath, new_path)
            fmode = filemode(new_path)
            # read-only
            chmod(new_path, fmode & (typemax(fmode) ⊻ 0o222))
        end

        return artifact_hash
    finally
        rm(temp_dir; recursive=true, force=true)
    end
end

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

function usages_toml()
    path = joinpath(first(Base.DEPOT_PATH), "logs", "my_artifact_usage.toml")
    mkpath(dirname(path))
    touch(path)
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

function orphanages_toml()
    path = joinpath(first(Base.DEPOT_PATH), "logs", "my_artifact_orphanages.toml")
    mkpath(dirname(path))
    touch(path)
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

        orphanage = Pair{String, DateTime}[]
        for (artifact_path, usage_dict) in usage_toml
            last_used_time = nothing

            for (artifacts_toml, entrys) in usage_dict
                if !isfile(artifacts_toml)
                    # the toml is already removed, so no such usage exist
                    if length(entrys) > 0
                        mtime = maximum(values(entrys))
                        last_used_time = isnothing(last_used_time) ? mtime : max(last_used_time, mtime)
                    end
                    delete!(usage_dict, artifacts_toml)
                else
                    # else we read the toml
                    artifact_dict = load_my_artifacts_toml(artifacts_toml)

                    # check that all usage entry is still exist, or remove them
                    for entry in keys(entrys)
                        if !haskey(artifact_dict, entry)
                            used_time = entrys[entry]
                            last_used_time = isnothing(last_used_time) ? used_time : max(last_used_time, used_time)
                            delete!(entrys, entry)
                        end
                    end

                    # if no entrys, remove this usage
                    isempty(entrys) && delete!(usage_dict, artifacts_toml)
                end
            end

            if isempty(usage_dict)
                # no usage of this artifact exist, mark it as orphan
                if isnothing(last_used_time)
                    last_used_time = now()
                end
                push!(orphanage, artifact_path=>last_used_time)
                delete!(usage_toml, artifact_path)
            end
        end

        # update usage toml
        let usage_toml = usage_toml
            open(usage_file, "w") do io
                TOML.print(io, usage_toml, sorted=true)
            end
        end

        # update the orphanage list
        old_orphans = if isfile(orphanage_file)
            parse_toml(orphanage_file)
        else
            Dict{String, DateTime}()
        end
        new_orphans = merge(old_orphans, Dict(orphanage))

        # mark orphanage for deletion
        gc_time = now()
        deletion_list = String[]
        for artifact_path in keys(new_orphans)
            last_used_time = new_orphans[artifact_path]
            if gc_time - last_used_time >= collect_delay
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
