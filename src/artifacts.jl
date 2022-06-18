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
