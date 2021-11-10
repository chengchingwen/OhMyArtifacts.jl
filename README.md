# OhMyArtifacts

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/dev)
[![Build Status](https://github.com/chengchingwen/OhMyArtifacts.jl/workflows/CI/badge.svg)](https://github.com/chengchingwen/OhMyArtifacts.jl/actions)
[![Coverage](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl)

Dynamic-created artifacts stored in scratchspace with single file content hash,
 for managing files that is unpacked and have many same subfiles.

# Comparison

1. Everything is stored in scratch space (created by Scratch.jl)
2. Differ from Artifacts.jl, the Artifacts.toml is created/modified dynamically instead of being fixed.
3. Also differ from Artifacts.jl, where each artifact is an directory identified by its sha1 tree hash,
 our artifact is a single file identified by sha256 content hash
4. Why? because I'm working on a system where remote files cannot be packed into tarball,
 and I only want some particular file in a remote directory. Besides, it's possible that there are
 two remote directories having same files but with different name and path.

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
