## foldertree ##

function _create_foldertree(source_dir, shadow_dir)
    # Calculate the tree hash for the dir
    artifact_hash = SHA256(Pkg.GitTools.tree_hash(SHA.SHA256_CTX, source_dir))

    # Calculate the relpath of all symlinks
    symlinks = Dict{String, Any}()
    for file in readdirfiles(source_dir)
        if islink(file)
            root = dirname(file)
            _link_path = readlink(file)
            abs_link_path = isabspath(_link_path) ? _link_path : abspath(joinpath(root, _link_path))
            if !(isfile(abs_link_path) || isdir(abs_link_path))
                @error "symlink $file points to non-exists file $abs_link_path, skip"
                continue
            end

            if !startswith(abs_link_path, abspath(source_dir))
                @error "symlink $file points to outside of input path $(abspath(source_dir)) thus skip: $abs_link_path"
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
        # skiping .git folder
        paths = splitpath(relroot)
        ".git" in paths && continue

        shadow_root = joinpath(shadow_dir, relroot) |> mkpath
        for dir in dirs
            joinpath(shadow_root, dir) |> mkpath
        end

        for file in files
            shadow_file_path = joinpath(shadow_root, file)
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

    return artifact_hash
end
