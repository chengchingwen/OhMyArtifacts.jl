# OhMyArtifacts

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/dev)
[![Build Status](https://github.com/chengchingwen/OhMyArtifacts.jl/workflows/CI/badge.svg)](https://github.com/chengchingwen/OhMyArtifacts.jl/actions)
[![Coverage](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl)

Dynamic-created artifacts stored in scratchspace with sha256 content or tree hash

# Design

The goal of OhMyArtifacts is to provide a caching api that entries can be added/removed during runtime.
 The cache is read-only and shared accross packages, that means there won't be any duplicated cache if
 they are all using OhMyArtifacts. The cache should also track the usage, so when no package is using that
 cache, it will be recycled automatically. The ownership of each cache should be able to delegate to the
 downstream package, so that when that package is removed, the cache can be freed.

## Comparison to builtin Artifact system (Artifacts.jl)

We already have a stdlib Artifacts.jl in Julia, Why would you need another one? The main reason is,
 the builtin artifacts system requires all artifacts to be known before runtime. The Artifact.toml is placed
 at the folder of that package, but since the package folder is read-only now, you cannot modify the
 Artifact.toml when you use the package. On the other hand, the cache of Artifacts.jl is based on directory
 tree hash, so even if there are multiple duplicate files in different diectory, they cannot share the cache.

## Comparison to Scratch Space API (Scratch.jl)

We are actually building on top of Scratch.jl. Scratch.jl provide a set of api for creating package-specific
 folder to store any kind of runtime data. In the Scratch.jl README, they also mention that you can
 [turn the scratch space into artifact](https://github.com/JuliaPackaging/Scratch.jl#can-i-use-a-scratch-space-as-a-temporary-workspace-then-turn-it-into-an-artifact). So precisely OhMyArtifacts is an implementation of that idea,
 but with some modification to the artifact caching behavior. Notice that our implementation is parallel to
 the builtin artifact system (Artifacts.jl), so generally it won't affect each other.



For more detail, read the [document](https://chengchingwen.github.io/OhMyArtifacts.jl/dev) or the comment in the source code

# API overview

```julia
module TestMod

using OhMyArtifacts

const my_artifacts = Ref{String}()

function __init__()
    my_artifacts[] = @my_artifacts_toml!()
    return
end

function download_file(name, url)
    global my_artifacts
    hash = create_my_artifact() do artifact_dir
        download(url, joinpath(artifact_dir, basename(url)))
    end
    bind_my_artifact!(my_artifacts[], name, hash)

    path = my_artifact_path(hash)
    return path
end

function data(name)
    hash = my_artifact_hash(name, my_artifacts[])
    return !isnothing(hash) && my_artifact_exists(hash) ? my_artifact_path(hash) : nothing
end

end # module
```

# Example

An OhMyArtifacts version of the iris example.

```julia
julia> using OhMyArtifacts
[ Info: Precompiling OhMyArtifacts [cf8be1f4-309d-442e-839d-29d2a0af6cb7]

# Register and get the Artifacts.toml
julia> myartifacts_toml = @my_artifacts_toml!();

# Query the Artifacts.toml for the hash bound to "iris"
julia> iris_hash = my_artifact_hash("iris", myartifacts_toml)

# If not bound
julia> if isnothing(iris_hash)
           iris_hash = create_my_artifact() do working_dir
               iris_url_base = "https://archive.ics.uci.edu/ml/machine-learning-databases/iris"
               download("$iris_url_base/iris.data", joinpath(working_dir, "iris.csv"))
               download("$iris_url_base/bezdekIris.data", joinpath(working_dir, "bezdekIris.csv"))
               download("$iris_url_base/iris.names", joinpath(working_dir, "iris.names"))
               # explicitly return the path
               return working_dir
           end
           bind_my_artifact!(myartifacts_toml, "iris", iris_hash)
       end

julia> iris_hash
SHA256("83c1aca5f0e9d222dee51861b3def4e789e57b17b035099570c54b51182853d4")

julia> my_artifact_exists(iris_hash)
true

# Get the artifact path
julia> iris_dataset_path = my_artifact_path(iris_hash);

julia> readdir(iris_dataset_path)
3-element Vector{String}:
 "bezdekIris.csv"
 "iris.csv"
 "iris.names"

julia> readline(joinpath(iris_dataset_path, "iris.names"))
"1. Title: Iris Plants Database"

# Every subfile is a symlink
julia> all(islink, readdir(iris_dataset_path, join=true))
true

julia> iris_name_url = "https://archive.ics.uci.edu/ml/machine-learning-databases/iris/iris.names";

# Helper function that combine create and bind
julia> iris_name_hash = download_my_artifact!(Base.download, iris_name_url, "iris.names", myartifacts_toml)
SHA256("38043f885d7c8cfb6d2cec61020b9bc6946c5856aadad493772ee212ef5ac891")

# Same value
julia> readline(my_artifact_path(iris_name_hash))
"1. Title: Iris Plants Database"

# Same file
julia> readlink(joinpath(iris_dataset_path, "iris.names")) == my_artifact_path(iris_name_hash)
true

# Unbind iris dataset
julia> unbind_my_artifact!(myartifacts_toml, "iris")

julia> using Dates

# Recycle: "iris/iris.names" is also used by "iris.names", only
#  remove 2 file ("iris/iris.csv", "iris/bezdekIris.csv") and 1 folder ("iris")
julia> OhMyArtifacts.find_orphanages(; collect_delay=Hour(0))
[ Info: 3 MyArtifacts deleted (24.889 KiB)

# "iris.names" still exists
julia> my_artifact_exists(iris_name_hash)
true

julia> readline(my_artifact_path(iris_name_hash))
"1. Title: Iris Plants Database"

# Iris dataset is removed
julia> my_artifact_exists(iris_hash)
false

julia> isdir(iris_dataset_path)
false

# Unbind and recycle
julia> unbind_my_artifact!(myartifacts_toml, "iris.names")

# When `using OhMyArtifacts`, this function is called if we haven't do it for 7 days, so
#  geneally we don't need to manually call it.
julia> OhMyArtifacts.find_orphanages(; collect_delay=Hour(0))
[ Info: 1 MyArtifact deleted (10.928 KiB)
```
