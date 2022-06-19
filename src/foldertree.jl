## foldertree ##

"""
    create_foldertree(f::Function)

Create multiple artifacts by doing `f(working_dir)`, hashing the content of `working_dir`, caching
 all files in the `working_dir`, shadowing the directory structure of `working_dir`, and returning
 the identifying hash of the directory.

See also: [`create_my_artifact`](@ref)
"""
function create_foldertree(f::Function)
    artifacts_dir = get_artifacts_dir()
    # create a tempdir in `myartifacts` dir
    temp_dir = mktempdir(artifacts_dir)

    source_dir = joinpath(temp_dir, "source") |> mkpath
    shadow_dir = joinpath(temp_dir, "shadow") |> mkpath

    try
        # Create files in the dir
        f(source_dir)

        # Calculate the tree hash for the dir
        artifact_hash = SHA256(Pkg.GitTools.tree_hash(SHA.SHA256_CTX, temp_dir))
        artifact_hash_str = string(artifact_hash)
        new_path = my_artifact_path(artifact_hash)

        # Calculate the relpath of all symlinks
        symlinks = Dict{String, Any}()
        for file in readdirfiles(source_dir)
            if islink(file)
                root = dirname(file)
                _link_path = readlink(file)
                abs_link_path = isabspath(_link_path) ? _link_path : abspath(joinpath(root, _link_path))
                if !(isfile(abs_link_path) || isdir(abs_link_path))
                    @error "symlink $file_path points to non-exists file $abs_link_path, skip"
                    continue
                end

                if !startswith(abs_link_path, abspath(source_dir))
                    @error "symlink $file_path points to outside of input path $(abspath(path)) thus skip: $abs_link_path"
                    continue
                end

                link_path = realpath(abs_link_path)
                isdirlink = isdir(link_path)
                link_target = relpath(link_path, root)
                symlinks[file] = (isdirlink, link_target)
            end
        end

        # Shadow the folder
        #   copy the folder structure into the shadow folder and cache each file,
        p = length(source_dir) + !isdirpath(source_dir)
        for (root, dirs, files) in walkdir(source_dir)
            relroot = chop(root, head=p, tail=0)
            shadow_root = joinpath(shadow_dir, relroot) |> mkpath
            for dir in dirs
                joinpath(shadow_root, dir) |> mkpath
            end

            for file in files
                shadow_file_path = joinpath(shadow_dir, file)
                file_path = joinpath(root, file)
                if islink(file_path)
                    if haskey(symlinks, file_path)
                        isdirlink, link_target = symlinks[file_path]
                        symlink(link_target, shadow_file_path; dir_target = isdirlink)
                    end
                else
                    hash = create_my_artifact() do working_dir
                        mv(file_path, joinpath(working_dir, file))
                    end
                    cache_path = my_artifact_path(hash)
                    symlink(cache_path, shadow_file_path; dir_target  = false)
                end
            end
        end

        filelock = mkpidlock(joinpath(artifacts_dir, "$(artifact_hash_str).lock"))
        try
            # skip if dir already exist (we already cache it)
            if !isdir(new_path)
                mv(shadow_dir, new_path)
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
    bind_foldertree!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false)

Writes a mapping of `name` -> `hash` in the given "Artifacts.toml" file and track the usage. This function
 also track the usage all the subfiles. If `force` is set to `true`, this will overwrite a pre-existant
 mapping, otherwise an error is raised.

See also: [`bind_my_artifact!`](@ref)
"""
function bind_foldertree!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false)
    bind_my_artifact!(artifacts_toml, name, hash; force)
    path = my_artifact_path(hash)
    for link in readdirfiles(path)
        file = readlink(link)
        if isabspath(file)
            file_hash = SHA256(basename(file))
            track_my_artifacts(artifacts_toml, name, file_hash)
        end
    end
    return
end
