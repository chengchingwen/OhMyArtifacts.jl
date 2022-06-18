const _SCRATCHSPACE = Ref{String}()

maybe_init() = need_init() && init()
function need_init()
    global _SCRATCHSPACE
    return !isdefined(_SCRATCHSPACE, :x)
end

"""
    init()

Initialize the storage space.

Generally you don't have to manually call this function. It would be called everytime you
 call `my_artifacts_toml!`. This function would setup the scratch space we need, check if
 we need to recycle some storages.
"""
function init()
    global _SCRATCHSPACE
    # Create `OMA` scratch space and artifacts folder
    scratchspace = @get_scratch!("0.3")
    _SCRATCHSPACE[] = scratchspace

    # `mkpath`s
    artifacts_dir = joinpath(scratchspace, "artifacts") |> mkpath
    log_dir = joinpath(scratchspace, "logs") |> mkpath

    # Log file path
    orphan_file = joinpath(log_dir, "my_artifact_orphanages.toml")
    usage_file  = joinpath(log_dir, "my_artifact_usage.toml")

    # `touch` files
    touch(usage_file)
    isfile(orphan_file) || touch(orphan_file)

    # Record modified time of the orphanage file
    last_gc_time = modified_time(orphan_file)
    # Make a cleanup if we haven't do it for 7 days
    (now() - last_gc_time >= Day(14)) && find_orphanages()

    return
end
