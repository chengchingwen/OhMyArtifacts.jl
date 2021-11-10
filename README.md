# OhMyArtifacts

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://chengchingwen.github.io/OhMyArtifacts.jl/dev)
[![Build Status](https://github.com/chengchingwen/OhMyArtifacts.jl/workflows/CI/badge.svg)](https://github.com/chengchingwen/OhMyArtifacts.jl/actions)
[![Coverage](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/chengchingwen/OhMyArtifacts.jl)

Automatically manage the `Artifacts.toml` configuration file by downloading files and calculating their hash.
This is useful for managing files that have many subfiles.

# API overview

```julia
module TestMod

using OhMyArtifacts

const my_artifact = Ref{String}()

function __init__()
    my_artifact[] = @my_artifacts_toml!()
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
