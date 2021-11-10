using OhMyArtifacts
using Documenter

DocMeta.setdocmeta!(OhMyArtifacts, :DocTestSetup, :(using OhMyArtifacts); recursive=true)

makedocs(;
    modules=[OhMyArtifacts],
    authors="chengchingwen <adgjl5645@hotmail.com> and contributors",
    repo="https://github.com/chengchingwen/OhMyArtifacts.jl/blob/{commit}{path}#{line}",
    sitename="OhMyArtifacts.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://chengchingwen.github.io/OhMyArtifacts.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/chengchingwen/OhMyArtifacts.jl",
)
