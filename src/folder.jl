function create_test_folder(dirpath)
    #= dirpath/
    my/
      a
      b
      c/
        d
        e --> ../a
      f --> abspath(path)/c/
    =#
    path = joinpath(dirpath, "my")
    mkpath(path)
    touch(joinpath(path, "a"))
    touch(joinpath(path, "b"))
    mkpath(joinpath(path, "c"))
    touch(joinpath(path, "c", "d"))
    symlink("../a", joinpath(path, "c", "e"); dir_target = false)
    symlink(joinpath(abspath(path), "c"), joinpath(path, "f"); dir_target = true)
    return path
end

function shadow_folder(path, target_path; shadow_prefix = "")
    isdir(path) || error("$path is not a directory")

    mkpath(target_path)

    symlinks = []
    for (root, dirs, files) in walkdir(path)
        target_root_path = joinpath(target_path, root)
        mkpath(target_root_path)
        for file in files
            target_file_path = joinpath(target_root_path, file)
            file_path = joinpath(root, file)
            if islink(file_path)
                # we defer the symlink creation to the last
                push!(symlinks, (root, file))
            else
                cp(file_path, target_file_path)
            end
        end

        for dir in dirs
            target_dir_path = joinpath(target_root_path, dir)
            mkpath(target_dir_path)
        end
    end

    for (root, file) in symlinks
        target_file_path = joinpath(target_path, root, file)
        file_path = joinpath(root, file)
        _link_path = readlink(file_path)

        abs_link_path = isabspath(_link_path) ? _link_path : abspath(joinpath(root, _link_path))
        if !(isfile(abs_link_path) || isdir(abs_link_path))
            @error "symlink $file_path points to non-exists file $abs_link_path, skip"
            continue
        end

        if !startswith(abs_link_path, abspath(path))
            @error "symlink $file_path points to outside of input path $(abspath(path)) thus skip: $abs_link_path"
            continue
        end
        link_path = realpath(abs_link_path)
        isdirlink = isdir(link_path)
        link_target = relpath(link_path, root)
        symlink(link_target, target_file_path; dir_target = isdirlink)
    end

    return target_path
end
