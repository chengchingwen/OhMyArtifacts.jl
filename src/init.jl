const _SCRATCHSPACE = Ref{String}()

maybe_init() = need_init() && init()
function need_init()
    global _SCRATCHSPACE
    return !isdefined(_SCRATCHSPACE, :x)
end

function get_scratchspace()
    global _SCRATCHSPACE
    maybe_init()
    return _SCRATCHSPACE[]
end

get_artifacts_dir() = joinpath(get_scratchspace(), "artifacts")
get_log_dir() = joinpath(get_scratchspace(), "logs")
orphanages_toml() = joinpath(get_log_dir(), "my_artifact_orphanages.toml")
usages_toml() = joinpath(get_log_dir(), "my_artifact_usage.toml")

const usage_lock_name = ".my_artifact_usage_lock"
const artifact_lock_name = "artifact_lock"

create_usage_lock(args...) = (global usage_lock_name; create_file_lock(args..., usage_lock_name))
create_artifact_lock(args...) = (global artifact_lock_name; create_file_lock(args..., artifact_lock_name))

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
