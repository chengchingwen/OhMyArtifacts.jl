# OhMyArtifacts

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/dev)
[![Build Status](https://github.com/chengchingwen/OhMyArtifacts.jl/workflows/CI/badge.svg)](https://github.com/chengchingwen/OhMyArtifacts.jl/actions)
[![Coverage](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl)

Dynamic-created artifacts stored in scratchspace with single file content hash,
 for managing files that is unpacked and have many same subfiles.

# Design

The goal of OhMyArtifacts is to provide a file caching api that entries can be added/removed during runtime.
 The cache is read-only and shared accross packages, that means there won't be any duplicated cache if
 they are all using OhMyArtifacts. The cache should also track the usage, so when no package is using that
 cache, it will be recycled automatically. The ownership of each cache should be able to delegate to the
 downstream package, so that when that package is removed, the cache can be freed.

## Comparison to builtin Artifact system ([Artifacts.jl](https://pkgdocs.julialang.org/v1/artifacts/))

We already have a stdlib Artifacts.jl in Julia, Why would you need another one? The main reason is,
 the builtin artifacts system requires all artifacts to be known before runtime. The Artifact.toml is placed
 at the folder of that package, but since the package folder is read-only now, you cannot modify the
 Artifact.toml when you use the package. On the other hand, the cache of Artifacts.jl is based on directory
 tree hash, so even if there are multiple duplicate files in different diectory, they cannot share the cache.

## Comparison to Scratch Space API ([Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl))

We are actually building on top of Scratch.jl. Scratch.jl provide a set of api for creating package-specific
 folder to store any kind of runtime data. In the Scratch.jl README, they also mention that you can
 [turn the scratch space into artifact](https://github.com/JuliaPackaging/Scratch.jl#can-i-use-a-scratch-space-as-a-temporary-workspace-then-turn-it-into-an-artifact). So precisely OhMyArtifacts is an implementation of that idea,
 but with some modification to the artifact caching behavior. Notice that our implementation is parallel to
 the builtin artifact system (Artifacts.jl), so generally it won't affect each other.

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
