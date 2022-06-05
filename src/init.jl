maybe_init() = need_init() && init()
function need_init()
    global ARTIFACTS_DIR
    return !isdefined(ARTIFACTS_DIR, :x)
end

"""
    init()

Initialize the storage space.

Generally you don't have to manually call this function. It would be called everytime you 
 call `my_artifacts_toml!`. This function would setup the scratch space we need, check if
 we need to recycle some storages.
"""
function init()
    global ARTIFACTS_DIR, LOG_DIR, _OLD_ARTIFACTS_DIR
    # Create `OMA` scratch space and artifacts folder
    artifacts_dir = @get_scratch!("ohmyartifacts")
    log_dir = @get_scratch!("logs")
    scratch_dir = dirname(artifacts_dir)
    ARTIFACTS_DIR[] = artifacts_dir
    LOG_DIR[] = log_dir
    _OLD_ARTIFACTS_DIR[] = joinpath(scratch_dir, "artifacts")

    # convert old cache structure to new one
    migration(scratch_dir)

    # Get orphanage file path
    orphan_file = orphanages_toml_path()
    # Get the last modified time of the orphange file (create orphanage file if not exist)
    last_gc_time = if isfile(orphan_file)
        modified_time(orphan_file)
    else
        orphanages_toml()
        now()
    end
    # Make a cleanup if we haven't do it for 7 days
    if now() - last_gc_time >= Day(7)
        find_orphanages()
    end

    return
end
