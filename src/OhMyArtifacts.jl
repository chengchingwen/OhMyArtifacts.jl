module OhMyArtifacts

using Pkg
using Pkg.Types: parse_toml
using SHA
using Dates
using Downloads
using Printf
using TOML
using Scratch
using Pidfile

export my_artifacts_toml!, @my_artifacts_toml!, @my_artifact
export create_my_artifact, bind_my_artifact!, download_my_artifact!,
    my_artifact_hash, my_artifact_path, my_artifact_exists

"""
    my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})

Return the path to (or creates) "Artifacts.toml" for the given `pkg`.

See also: [`@my_artifacts_toml!`](@ref)
"""
function my_artifacts_toml!(pkg::Union{Module,Base.UUID,Nothing})
    # initialize OhMyArtifacts
    init()

    # Create the `pkg` scratch space in `OMA` scratch space
    #   with `pkg` uuid as the name, and delegate the ownership
    #   of that space to `pkg`, so when `pkg` get removed, it
    #   could also recycle this scratch space
    scratchspace = get_scratchspace()
    uuid = Scratch.find_uuid(pkg)
    path = joinpath(scratchspace, string(uuid)) |> mkpath
    Scratch.track_scratch_access(uuid, path)

    # create & return Artifacts.toml in `pkg` scratch space
    return touch(joinpath(path, "Artifacts.toml"))
end

include("./utils.jl")

# setup & initializing the space
include("./init.jl")
include("./macro.jl")

# artifacts api
include("./artifacts.jl")

# foldertree api
# include("./foldertree.jl")

# recycle
include("./recycle.jl")

end
