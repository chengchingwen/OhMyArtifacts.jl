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
    prefix = bytes2hex((hash.bytes[1],))
    dir = joinpath(artifacts_dir, prefix) |> mkpath
    path = joinpath(dir, string(hash))
    return path
end

"""
    my_artifact_exists(hash::SHA256)

Returns whether the given artifact (identified by its SHA256 content hash) exists on-disk.
"""
function my_artifact_exists(hash::SHA256)
    path = my_artifact_path(hash)
    return isfile(path) || isdir(path)
end

"""
    create_my_artifact(f::Function)

Create artifact by calling `f(working_dir)`. `f` is the function that create/put/download file(s) into
 the `working_dir`. `f` should either return the path to the file/directory or return `nothing`. If `f`
 return `nothing`, then everything in `working_dir` would be cached. If `f` return a path, that path
 must be inside `working_dir`.
"""
function create_my_artifact(f::Function)
    artifacts_dir = get_artifacts_dir()
    # create a tempdir in `myartifacts` dir
    temp_dir = mktempdir(artifacts_dir)
    source_dir = joinpath(temp_dir, "source") |> mkpath
    shadow_dir = joinpath(temp_dir, "shadow") |> mkpath

    try
        # create file in temp dir
        path = f(source_dir)

        path = if isnothing(path)
            source_dir
        else
            if isabspath(path)
                path |> abspath
            else
                # not getting abspath, try concat with working dir
                joinpath(source_dir, path) |> abspath
            end
        end

        # make sure the returned path is correct
        !startswith(path, source_dir) && error("returned path $path result outside of the given dir")

        if isfile(path)
            # calculate the file hash
            artifact_hash = SHA256(Pkg.GitTools.blob_hash(SHA.SHA256_CTX, path))
        elseif isdir(path)
            # calculate the tree hash and copy the directory structure
            artifact_hash = _create_foldertree(path, shadow_dir)
        else
            error("returned path does not exist: $path")
        end

        artifact_hash_str = string(artifact_hash)
        new_path = my_artifact_path(artifact_hash)

        # Create a file lock in `artifacts` dir with name `$hash.lock`.
        # avoid other process creating the same cache at the same time.
        filelock = mkpidlock(joinpath(artifacts_dir, "$(artifact_hash_str).lock"))
        try
            if isfile(path)
                # skip if file already exist (we already cache it)
                if !isfile(new_path)
                    mv(path, new_path)
                    fmode = filemode(new_path)
                    # read-only
                    chmod(new_path, fmode & (typemax(fmode) ⊻ 0o222))
                end
            elseif isdir(path)
                # skip if dir already exist (we already cache it)
                if !isdir(new_path)
                    mv(shadow_dir, new_path)
                    fmode = filemode(new_path)
                    # read-only
                    chmod(new_path, fmode & (typemax(fmode) ⊻ 0o222))
                end
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
    bind_my_artifact!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false, metadata = nothing)

Writes a mapping of `name` -> `hash` in the given "Artifacts.toml" file and track the usage. If `force`
 is set to `true`, this will overwrite a pre-existant mapping, otherwise an error is raised. By setting
 `metadata`, we can store extra information in the `artifacts_toml` with field name `meta` of `name` entry.
"""
function bind_my_artifact!(artifacts_toml::String, name::AbstractString, hash::SHA256;
                           force::Bool = false, metadata = nothing)
    artifact_path = my_artifact_path(hash)
    @assert my_artifact_exists(hash) "artifact with hash $hash is not exist: must do `create_my_artifact` beforehand."
    _bind_single_artifact!(artifacts_toml, name, hash; force, metadata)
    if isdir(artifact_path)
        # artifact is a directory, track all subfiles
        for link in readdirfiles(artifact_path)
            # every file in the shadow folder is a symlink
            file = readlink(link)
            # if link is not an abspath, its a symlink point to another subfile (i.e. another symlink)
            if isabspath(file)
                file_hash = SHA256(basename(file))
                track_my_artifacts(artifacts_toml, name, file_hash)
                # It's possible different link point to same cache, but since they are track as same name,
                #   track function simply update the using time.
            end
        end
    end
    return
end

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

"""
    unbind_my_artifact!(artifacts_toml::String, names::Vector{String})

Unbind the given list of `names` from the "Artifacts.toml" file.
"""
function unbind_my_artifact!(artifacts_toml::String, names)
    # Create a file lock with name `artifact_lock`. `load`/`bind` would need to wait
    #   until `unbind`ing finish
    artifact_lock = create_artifact_lock(artifacts_toml)
    try
        artifact_dict = parse_toml(artifacts_toml)

        for name in names
            # If the binding doesn't exist, skip
            !haskey(artifact_dict, name) && continue
            # Remove the binding from artifacts toml
            delete!(artifact_dict, name)
        end

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
