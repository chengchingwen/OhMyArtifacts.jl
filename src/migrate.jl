function migration(scratch_dir)
    global _OLD_ARTIFACTS_DIR

    # artifact migration
    old_artifacts_dir = _OLD_ARTIFACTS_DIR[]
    artifacts_dir = get_artifacts_dir()
    if isdir(old_artifacts_dir)
        for artifact_path in readdirfiles(old_artifacts_dir)
            hash = tryparse(SHA256, basename(artifact_path))
            # not a cache
            isnothing(hash) && continue

            # skip if it's a symlink (migration done already)
            if isfile(artifact_path) && !islink(artifact_path)
                new_artifact_path = my_artifact_path(hash)

                filelock = mkpidlock(joinpath(artifacts_dir, "$(hash).lock"))
                try
                    if !isfile(new_artifact_path)
                        # not found in new cache
                        mv(artifact_path, new_artifact_path)
                        fmode = filemode(new_artifact_path)
                        # read-only
                        chmod(new_artifact_path, fmode & (typemax(fmode) ⊻ 0o222))
                    else
                        # cache already in new cache
                        rm(artifact_path; recursive=true, force=true)
                    end
                    # add symlink at old cache
                    symlink(new_artifact_path, artifact_path)
                finally
                    close(filelock)
                end
            end
        end
    end

    # Old file exist and is not a symlink -> config migration
    old_orphan_file = joinpath(scratch_dir, "my_artifact_orphanages.toml")
    old_usage_file = joinpath(scratch_dir, "my_artifact_usage.toml")
    new_usage_file = usages_toml()
    new_orphan_file = orphanages_toml()
    if isfile(old_usage_file) && !islink(old_usage_file)
        old_usage_lock = nothing
        new_usage_lock = nothing
        try
            old_usage_lock = create_usage_lock(old_usage_file)
            new_usage_lock = create_usage_lock(new_usage_file)

            usage_toml = parse_toml(old_usage_file)
            new_usage_toml = parse_toml(new_usage_file)
            for (old_artifact_path, usage_dict) in usage_toml
                hash = SHA256(basename(old_artifact_path))
                new_artifact_path = my_artifact_path(hash)
                new_usage_dict = get!(new_usage_toml, new_artifact_path, Dict{String, Any}())
                merge_toml!(new_usage_dict, usage_dict)
            end
            let usage_toml = new_usage_toml
                open(new_usage_file, "w") do io
                    TOML.print(io, usage_toml, sorted=true)
                end
            end

            orphans = parse_toml(old_orphan_file)
            new_orphans = parse_toml(new_orphan_file)
            for (old_artifact_path, last_gc_time) in orphans
                hash = SHA256(basename(old_artifact_path))
                new_artifact_path = my_artifact_path(hash)
                if haskey(new_orphans, new_artifact_path)
                    new_orphans[new_artifact_path] = min(new_orphans[new_artifact_path], last_gc_time)
                else
                    new_orphans[new_artifact_path] = last_gc_time
                end
            end
            let new_orphans = new_orphans
                open(new_orphan_file, "w") do io
                    TOML.print(io, new_orphans, sorted=true)
                end
            end

            # replace old file with symlink
            rm(old_orphan_file; recursive=true, force=true)
            rm(old_usage_file; recursive=true, force=true)
            symlink(new_orphan_file, old_orphan_file)
            symlink(new_usage_file, old_usage_file)
        finally
            isnothing(old_usage_lock) || close(old_usage_lock)
            isnothing(new_usage_lock) || close(new_usage_lock)
        end
    end

    return
end

function isnewpath(path)
    dir = basename(dirname(path))
    return length(dir) == 2 && startswith(basename(path), dir)
end

function merge_usage_toml(usage_toml)
    new_usage_toml = Dict{String, Any}()
    artifacts_dir = get_artifacts_dir()
    for (artifact_path, usage_dict) in usage_toml
        hash = SHA256(basename(artifact_path))
        new_artifact_path = my_artifact_path(hash)
        # merge new and old cache log
        new_usage_dict = get!(new_usage_toml, new_artifact_path, Dict{String, Any}())
        merge_toml!(new_usage_dict, usage_dict)

        # keep old cache log, so the symlink can removed if needed
        if !isnewpath(artifact_path)
            new_usage_toml[artifact_path] = usage_dict
        end
    end

    return new_usage_toml
end
