# Design

The goal of OhMyArtifacts is to provide a file caching api that entries can be added/removed during runtime.
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


## How (v0.2)

We mentioned a few features and issues that we want to solve, but how does it work? General speaking,
 we place all the artifacts in the scratch space of OhMyArtifacts. The directory
 structure would look like this:

```
OhMyArtifacts-scratchspace/
  |- artifacts/
	|- <some sha256 string>
	...
  |- my_artifact_usage.toml
  |- my_artifact_orphanages.toml
  |- Package-A-scratchspace/
	|- Artifacts.toml
  |- Package-B-scratchspace/
  |- ...
  ...
```

1. The `artifacts` folder contains all the cache. Each cache is a read-only file whose name is its
 content sha256 hash.
2. `my_artifact_usage.toml` is a log file, which track all the usage of each cache. Can be seemed as
 a dictionary mapping from cache to a list of Artifacts.toml that use that cache. We use this to know
 whether a cache can be recycled without causing problems.
3. `my_artifact_orphanages.toml` is a log file, which track the time that we find a cache is not used
 by any Artifacts.toml any more. So when the recycle mechanism happened, it will check whether the cache
 is not used for a given period of time, then recycle it if it exceeds the range.
4. For each package that use OhMyArtifacts, we create another scratch space for it in our scratch space.
 When the package is removed, this scratch space might also be recycled, so we would know that the
 usage/orphanages toml will need to be updated. This depends on the recycle mechanism of Scratch.jl.
5. The Artifacts.toml in the scratchspace is the entry point of the OhMyArtifacts api. When caching
 a file, the api would create a mapping in the Artifacts.toml which map from a name to a sha256 hash.
 So when loading the file, the path is just the path of `artifacts` folder with the hash.
