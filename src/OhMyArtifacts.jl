module OhMyArtifacts

using Pkg
using Pkg.Artifacts
using Pkg.Types: parse_toml
using SHA
using Dates
using Downloads
using Printf
using TOML
using Scratch
using Pidfile

export my_artifacts_toml!, @my_artifacts_toml!, create_my_artifact, bind_my_artifact!,
    my_artifact_hash, my_artifact_path, my_artifact_exists,
    @my_artifact, download_my_artifact!


const ARTIFACTS_TOML_VAR_SYM = Ref{Symbol}(:my_artifacts)

include("./init.jl")


"""
    my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})

Return the path to (or creates) "Artifacts.toml" for the given `pkg`.

See also: [`@my_artifacts_toml!`](@ref)
"""
function my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})
    # initialize OhMyArtifacts
    init()

    # Create the `pkg` scratch space in `OMA` scratch space
    #   with `pkg` uuid as the name, and delegate the ownership
    #   of that space to `pkg`, so when `pkg` get removed, it
    #   could also recycle this scratch space
    scratchspace = get_scratchspace()
    uuid = Scratch.find_uuid(pkg)
    path = joinpath(scratchspace, string(uuid)) |> mkpath
    Scratch.track_scratch_access(uuid, path)

    # create & return Artifacts.toml in `pkg` scratch space
    return touch(joinpath(path, "Artifacts.toml"))
end

## utilities

_merge(d::AbstractDict...) = mergewith(_merge, d...)
_merge(d::DateTime...) = min(d...)
merge_toml(d...) = mergewith(_merge, d...)
merge_toml!(d...) = mergewith!(_merge, d...)

function write_toml(file, toml)
    open(file, "w") do io
        TOML.print(io, toml, sorted=true)
    end
end

readdirfiles(dir) = mapreduce(x->map(Base.Fix1(joinpath, x[1]), x[end]), append!, walkdir(dir); init=String[])

# function get_scratch_dir()
#     return mkpath(scratch_dir(string(Base.PkgId(@__MODULE__).uuid)))
# end

function get_scratchspace()
    global _SCRATCHSPACE
    maybe_init()
    return _SCRATCHSPACE[]
end

get_artifacts_dir() = joinpath(get_scratchspace(), "artifacts")
get_log_dir() = joinpath(get_scratchspace(), "logs")
orphanages_toml() = joinpath(get_log_dir(), "my_artifact_orphanages.toml")
usages_toml() = joinpath(get_log_dir(), "my_artifact_usage.toml")

function get_artifacts_toml_sym()
    global ARTIFACTS_TOML_VAR_SYM
    return ARTIFACTS_TOML_VAR_SYM[]
end

function modified_time(file)
    return Dates.unix2datetime(mtime(file)) + round(now() - now(Dates.UTC), Hour)
end

create_file_lock(file, lock_name) = mkpidlock(joinpath(dirname(file), lock_name))
create_file_lock(f::Function, file, lock_name) = mkpidlock(f, joinpath(dirname(file), lock_name))

const usage_lock_name = ".my_artifact_usage_lock"
const artifact_lock_name = "artifact_lock"

create_usage_lock(args...) = (global usage_lock_name; create_file_lock(args..., usage_lock_name))
create_artifact_lock(args...) = (global artifact_lock_name; create_file_lock(args..., artifact_lock_name))

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

include("./macro.jl")

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

"""
    load_my_artifacts_toml(artifacts_toml::String)

Safely read the `artifacts_toml`, return a `Dict{String, Any}` of binding name to sha256 hash.
"""
function load_my_artifacts_toml(artifacts_toml::String)
    # Create a file lock with name `artifact_lock` and parse the toml.
    # Avoid parallel read write with the lock, so if other process is
    #   `bind`ing/`unbind`ing, it will wait until they finish to read the toml
    artifact_dict = create_artifact_lock(artifacts_toml) do
        parse_toml(artifacts_toml)
    end
    return artifact_dict
end

"""
    my_artifact_hash(name::AbstractString, artifacts_toml::String)

Return the hash found in `artifacts_toml` with given `name`, or `nothing` if not found.
"""
function my_artifact_hash(name::AbstractString, artifacts_toml::String)
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
    prefix = bytes2hex(hash.bytes[1])
    dir = joinpath(artifacts_dir, prefix) |> mkpath
    path = joinpath(dir, string(hash))
    return path
end

"""
    my_artifact_exists(hash::SHA256)

Returns whether the given artifact (identified by its SHA256 content hash) exists on-disk.
"""
function my_artifact_exists(hash::SHA256)
    return isfile(my_artifact_path(hash))
end

"""
    create_my_artifact(f::Function)

Create a new artifact by doing `path = f(working_dir)`, hashing the content of returned file pointed
 by `path`, and moving it to the artifact store. Returns the identifying hash of this artifact.

`f(working_dir)` should return an absolute path to a single file at the top level of `working_dir`.
"""
function create_my_artifact(f::Function)
    artifacts_dir = get_artifacts_dir()
    # create a tempdir in `ohmyartifacts` dir
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
        artifact_hash_str = string(artifact_hash)
        new_path = my_artifact_path(artifact_hash)

        # Create a file lock in `ohmyartifacts` dir with name `$hash.lock`.
        # avoid other process creating the same cache at the same time.
        filelock = mkpidlock(joinpath(artifacts_dir, "$(artifact_hash_str).lock"))
        try
            # skip if file already exist (we already cache it)
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
    bind_my_artifact!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false)

Writes a mapping of `name` -> `hash` within the given "Artifacts.toml" file. If `force` is set to `true`,
 this will overwrite a pre-existant mapping, otherwise an error is raised.
"""
function bind_my_artifact!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false)
    # Create a file lock with name `artifact_lock`. `load`/`unbind` would need to wait
    #   until `bind`ing finish
    artifact_lock = create_artifact_lock(artifacts_toml)
    try
        artifact_dict = parse_toml(artifacts_toml)

        # If mapping already exist, make warning if `force`, otherwise error out.
        if haskey(artifact_dict, name)
            if force
                @warn "Mapping for $name within $(artifacts_toml) is replaced forcely"
            else
                error("Mapping for $name within $(artifacts_toml) already exists!")
            end
        end

        meta =  Dict{String,Any}(
            "sha256" => string(hash),
        )

        artifact_dict[name] = meta
        # Write the result to file
        write_toml(artifacts_toml, artifact_dict)
    finally
        close(artifact_lock)
    end

    track_my_artifacts(artifacts_toml, name, hash)
    return
end

function track_my_artifacts(artifacts_toml::String, name::AbstractString, hash::SHA256)
    usage_file = usages_toml()
    artifact_path = my_artifact_path(hash)

    # Create a file lock with name ".my_artifact_usage_lock" at the same folder of usage_file
    # block `find_orphanages`
    usage_lock = create_usage_lock(usage_file)
    try
        # update the usage dict of that cache.
        #
        #   usage log :: Dict{Cache_path => Dict{Artifact_toml_path => Dict{Binding_name => usage_time}}}
        #
        #   The usage log (toml) is a nested dictionary mapping from the cache (path) to the usage dict.
        #
        #   A usage dict (`artifact_usage`) is a nested dictionary mapping from the artifact toml (path)
        #     to the binding dict.
        #
        #   A binding dict (inner-most part) is a dictionary mapping from the binding name to the time
        #     that the binding was created.
        usage_toml = parse_toml(usage_file)

        if haskey(usage_toml, artifact_path)
            # the cache has been used before, get usage dict
            artifact_usage = usage_toml[artifact_path]
            if haskey(artifact_usage, artifacts_toml)
                # the artifact toml already has a binding to the same cache
                # add a new binding name created time
                artifact_usage[artifacts_toml][name] = now()
            else
                # no binding exist for this cache, create new binding dict
                artifact_usage[artifacts_toml] = Dict(name => now())
            end
        else
            # the cache hasn't been used before, create new usage dict
            usage_dict = Dict{String, Any}(
                artifacts_toml => Dict{String, Any}(
                    name => now()
                )
            )
            usage_toml[artifact_path] = usage_dict
        end

        # Write the result to file
        write_toml(usage_file, usage_toml)
    finally
        close(usage_lock)
    end
    return
end

"""
    download_my_artifact!([downloadf::Function = Downloads.download], url, name::AbstractString, artifacts_toml::String;
                         force_bind::Bool = false, downloadf_kwarg...)

Convenient function that do download-create-bind together and return the content hash.
 Download function `downloadf` should take two position arguments
 (i.e. `downloadf(url, dest; downloadf_kwarg...)`). if `force_bind` is `true`,
 it will overwrite the pre-existant binding.

See also: [create_my_artifact](@ref), [bind_my_artifact!](@ref)
"""
function download_my_artifact!(downloadf::Function, url, name::AbstractString, artifacts_toml::String;
                               force_bind::Bool = false, downloadf_kwarg...)
    # Create file lock with url sha1 hash as the lock name
    #   Avoid multiple downloading at the same time. It will still download the file
    #   multiple times, but not at the same time. This is unavoidable because we use
    #   content hash and we cannot know the the content hash without actual downloading.
    lockname = bytes2hex(sha1(string(url)))
    hash = create_file_lock(artifacts_toml, "$(lockname).lock") do
        create_my_artifact() do artifact_dir
            downloadf(url, tempname(artifact_dir; cleanup=false); downloadf_kwarg...)
        end
    end
    bind_my_artifact!(artifacts_toml, name, hash; force = force_bind)

    return hash
end
download_my_artifact!(
    url, name::AbstractString, artifacts_toml::String;
    force_bind::Bool = false, downloadf_kwarg...,
) =
    download_my_artifact!(Downloads.download, url, name, artifacts_toml; force_bind, downloadf_kwarg...)

"""
    unbind_my_artifact!(artifacts_toml::String, name::AbstractString)

Unbind the given `name` from the "Artifacts.toml" file. Silently fails if no such binding exists within the file.
"""
function unbind_my_artifact!(artifacts_toml::String, name::AbstractString)
    # Create a file lock with name `artifact_lock`. `load`/`bind` would need to wait
    #   until `unbind`ing finish
    artifact_lock = create_artifact_lock(artifacts_toml)
    try
        artifact_dict = parse_toml(artifacts_toml)

        # If the binding doesn't exist, skip
        !haskey(artifact_dict, name) && return

        hash = artifact_dict[name]["sha256"]
        # Remove the binding from artifacts toml
        delete!(artifact_dict, name)

        # Write the result to file
        #   Notice that we didn't update the usage dict at this moment.
        #     It's done in `find_orphanages` so that we don't frequently update
        #     the usage toml.
        write_toml(artifacts_toml, artifact_dict)
    finally
        close(artifact_lock)
    end
    return
end

function find_orphanages(; collect_delay::Period=Day(7))
    artifacts_dir = get_artifacts_dir()
    usage_file = usages_toml()
    orphanage_file = orphanages_toml()

    # Create a file lock with name ".my_artifact_usage_lock" at the same folder of usage_file
    # block `track_my_artifacts`
    #   This is the only function that read/write to orphanages log, so no need to lock it.
    #     Parallel call to this function will be block by usage lock.
    usage_lock = create_usage_lock(usage_file)
    try
        usage_toml = parse_toml(usage_file)

        # find orphan artifacts
        # orphanage :: Vector{Cache_path => Last_modified_time}
        orphanage = Pair{String, DateTime}[]

        # Find artifact without binding
        #   Check from all exist cache. If all bindings for that cache are safely removed by `unbind`
        #     (and usage toml has been updated in the previous `find_orphanages`, the usage dict will
        #     be empty and thus no record in usage log.
        #
        #   For all cache in the `ohmyartifacts` dir, check if there exist a record in the usage log.
        #     If not, add to `orphanage`. They can be removed safely.
        for artifact_path in readdirfiles(artifacts_dir)
            hash = tryparse(SHA256, basename(artifact_path))
            # not a cache
            isnothing(hash) && continue

            if !haskey(usage_toml, artifact_path)
                push!(orphanage, artifact_path=>modified_time(artifact_path))
            end
        end

        # Check artifact with binding
        #   Check from usage log.
        #
        #   If a Artifact toml is removed due to scratch space recycling,
        #     the usage log would still has an entry for it, but the linked artifact toml file
        #     does not exist.
        #
        #   If a binding is removed with `unbind`, since we didn't update the usage toml at that moment,
        #     the usage update is done here.
        curr_gc_time = now()
        for (artifact_path, usage_dict) in usage_toml
            # check if all bindings are removed

            for (artifacts_toml, entrys) in usage_dict
                if !isfile(artifacts_toml)
                    # the toml is already removed, so no such usage exist
                    delete!(usage_dict, artifacts_toml)
                else
                    # This block is for updating the usage toml after unbinding.
                    #   We didn't directly update usage toml each time the `unbind`
                    #     is called, instead we check if the binding is `unbind`ed
                    #     here so that the update can be done all at once.

                    # else we read the toml
                    artifact_dict = load_my_artifacts_toml(artifacts_toml)

                    # check that all usage entry is still exist, or remove them
                    for entry in keys(entrys)
                        if !haskey(artifact_dict, entry)
                            # binding not found, removed
                            delete!(entrys, entry)
                        else
                            # binding exist, make sure it did not get force update
                            hash = artifact_dict[entry]["sha256"]
                            if hash != basename(artifact_path)
                                # binding is forcely updated
                                delete!(entrys, entry)
                            end
                        end
                    end

                    # if no binding exists, remove this usage
                    isempty(entrys) && delete!(usage_dict, artifacts_toml)
                end
            end

            if isempty(usage_dict)
                # no usage of this cache exist
                # mark it as orphan and record the current time
                push!(orphanage, artifact_path=>curr_gc_time)
                delete!(usage_toml, artifact_path)
            end
        end

        # update usage toml
        write_toml(usage_file, usage_toml)

        # merge old and new orphan list
        #   if the entry already on the list, keep the old recorded time
        new_orphans = Dict(orphanage)
        old_orphans = parse_toml(orphanage_file)
        for artifact_path in keys(new_orphans)
            if haskey(old_orphans, artifact_path)
                new_orphans[artifact_path] = old_orphans[artifact_path]
            end
        end

        # mark orphanage for deletion
        #   If the cache become an orphan for more than `collect_delay` time, it should be deleted.
        gc_time = now()
        deletion_list = String[]
        for (artifact_path, last_gc_time) in new_orphans
            if gc_time - last_gc_time >= collect_delay
                push!(deletion_list, artifact_path)
                delete!(new_orphans, artifact_path)
            end
        end

        # update the resulted orphanage to file
        write_toml(orphanage_file, new_orphans)

        # delete my artifacts
        # BEGIN: utility functions for deletion
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
        # END: utility functions for deletion

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
