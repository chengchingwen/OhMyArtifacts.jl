# MyArtifacts

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://chengchingwen.github.io/MyArtifacts.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://chengchingwen.github.io/MyArtifacts.jl/dev)
[![Build Status](https://github.com/chengchingwen/MyArtifacts.jl/workflows/CI/badge.svg)](https://github.com/chengchingwen/MyArtifacts.jl/actions)
[![Coverage](https://codecov.io/gh/chengchingwen/MyArtifacts.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/chengchingwen/MyArtifacts.jl)

Dynamic-created artifacts stored in scratchspace with single file content hash,
 for managing files that is unpacked and have many same subfiles.

# API overview

```julia
module TestMod

using MyArtifacts

const my_artifact = Ref{String}()

function __init__()
    my_artifact[] = my_artifacts_toml!(@__MODULE__)
    return
end

function download_file(name, url)
	global my_artifact
	hash = create_my_artifact() do artifact_dir
		download(url, joinpath(artifact_dir, basename(url)))
	end
	bind_my_artifact!(my_artifact[], name, hash)
	
	path = my_artifact_path(hash)
	return path
end

end # module
```
