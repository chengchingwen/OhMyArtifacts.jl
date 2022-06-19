## recycle ##

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
        #   For all cache in the `artifacts` dir, check if there exist a record in the usage log.
        #     If not, add to `orphanage`. They can be removed safely.
        for artifact_path in readdirdepth(==(1), artifacts_dir)
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
        foldertree_usage = Dict{String, Any}()
        for (artifact_path, usage_dict) in usage_toml
            # check if all bindings are removed
            artifact_hash = basename(artifact_path)
            artifact_type = isdir(artifact_path)

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
                            bound_path = my_artifact_path(SHA256(hash))
                            bound_type = isdir(bound_path)
                            if artifact_type == bound_type
                                # same kinds of cache (both file or both folder)
                                if hash != artifact_hash
                                    # binding is forcely updated
                                    delete!(entrys, entry)
                                end
                            else
                                if artifact_type # artifact is dir but replaced by file
                                    # simply remove the entry
                                    delete!(entrys, entry)
                                else
                                    # Either artifact is file but replaced by dir,
                                    #   or artifact is the subfile of that folder.

                                    # Record that folder `bound_path` might have a usage
                                    #   to `artifact_path`, would need to delete from `entrys`,
                                    #   at binging `entry`.
                                    #
                                    # We defer the update of folder so we don't have to walk through
                                    #   the dir multiple times.
                                    #
                                    # foldertree_usage :: Dict{DirPath =>
                                    #                          Dict{CachePath => Dict{Mappings => List{Binding}}}}
                                    if haskey(foldertree_usage, bound_path)
                                        folder_usage_dict = foldertree_usage[bound_path]
                                        folder_usage_entrys = get!(folder_usage_dict, artifact_path, Dict())
                                        folder_usage_list = get!(folder_usage_entrys, entrys, [])
                                        push!(folder_usage_list, entry)
                                    else
                                        foldertree_usage[bound_path] = Dict{String, Any}(
                                            artifact_path => Dict{Any, Any}(
                                                entrys => Any[entry]
                                            )
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        for (folder_path, file_dict) in foldertree_usage
            # read all lnik points to cache in the folder
            subfiles = foldl(Iterators.map(readlink, readdirfiles(folder_path)); init=String[]) do s, f
                isabspath(f) && push!(s, f)
                return s
            end

            for subfile in subfiles
                # if those mapping are pointing to correct folder, removed from dict.
                #   The rest will be treat as orphans
                if haskey(file_dict, subfile)
                    delete!(file_dict, subfile)
                end
            end

            # remove the entry that points to the wrong dir
            for (artifacts_path, mapping_dict) in file_dict
                for (entrys, entry_list) in mapping_dict
                    for entry in entry_list
                        delete!(entrys, entry)
                    end
                end
            end
        end

        # check if any entrys or usage dict is empty and remove them, the result is the new usage toml
        for (artifact_path, usage_dict) in usage_toml
            for (artifacts_toml, entrys) in usage_dict
                # if no binding exists, remove this usage
                isempty(entrys) && delete!(usage_dict, artifacts_toml)
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

        function delete_folder(path)
            path_size = file_size(path)
            try
                Base.Filesystem.prepare_for_deletion(path)
                Base.rm(path; recursive=false, force=true)
            catch e
                @warn("Failed to delete $path", exception=e)
                return 0
            end
            return path_size
        end
        # END: utility functions for deletion

        # remove artifacts
        space_freed = 0
        for artifact_path in deletion_list
            space_freed += delete_path(artifact_path)
        end

        for dir in readdirdepth(==(0), artifacts_dir; dirs_only=true)
            # remove empty folders
            if length(basename(dir)) == 2 && isempty(readdir(dir))
                space_freed += delete_folder(dir)
            end
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
