## artifacts ##

function _bind_single_artifact!(artifacts_toml::String, name::AbstractString, hash::SHA256; force::Bool = false)
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
            "isdir" => isdir(my_artifact_path(hash)),
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
