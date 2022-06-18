## foldertree ##

"""
    my_foldertree_path(hash::SHA256)

Given a tree hash, return its intallation path. If the foldertree does not exist, return the location it would be
 installed to.

See also: [`my_foldertree_exists`](@ref)
"""
function my_foldertree_path(hash::SHA256)
    foldertree_dir = get_foldertree_dir()
    prefix = bytes2hex(hash.bytes[1])
    dir = joinpath(foldertree_dir, prefix) |> mkpath
    path = joinpath(dir, string(hash))
end

"""
    my_foldertree_exists(hash::SHA256)

Returns whether the given foldertree (identified by its SHA256 content hash) exists on-disk.
"""
function my_foldertree_exists(hash::SHA256)
    return isfile(my_foldertree_path(hash))
end

"""
    create_my_artifact_dir(f::Function)

Create multiple artifacts by doing `f(working_dir)`, hashing the content of `working_dir`, caching
 all files in the `working_dir`, shadowing the directory structure of `working_dir`, and returning
 the identifying hash of the directory.
"""
function create_my_artifact(f::Function)
    foldertree_dir = get_artifacts_dir()
    # create a tempdir in `myartifacts` dir
    temp_dir = mktempdir(artifacts_dir)

    try
        # Create files in temp dir
        f(temp_dir)

        # Calculate the tree hash for the temp dir
        artifact_hash = SHA256(Pkg.GitTools.tree_hash(SHA.SHA256_CTX, temp_dir))
        artifact_hash_str = string(artifact_hash)
        

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

