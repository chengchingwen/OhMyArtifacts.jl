using MyArtifacts
using Documenter

DocMeta.setdocmeta!(MyArtifacts, :DocTestSetup, :(using MyArtifacts); recursive=true)

makedocs(;
    modules=[MyArtifacts],
    authors="chengchingwen <adgjl5645@hotmail.com> and contributors",
    repo="https://github.com/chengchingwen/MyArtifacts.jl/blob/{commit}{path}#{line}",
    sitename="MyArtifacts.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://chengchingwen.github.io/MyArtifacts.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/chengchingwen/MyArtifacts.jl",
)
