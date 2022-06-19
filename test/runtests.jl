using OhMyArtifacts, Pkg, Dates
using Scratch
using Test
include("utils.jl")

# Set to true for verbose Pkg output
const verbose = false
global const pkgio = verbose ? stderr : (VERSION < v"1.6.0-DEV.254" ? mktemp()[2] : devnull)

read_artifacts() = OhMyArtifacts.readdirdepth(==(1), OhMyArtifacts.get_artifacts_dir())

function list_folder(path)
    p = length(path) + !isdirpath(path)
    sort!(map(f->chop(f, head=p, tail=0), OhMyArtifacts.readdirdepth(Base.Fix2(isa, Int), path)))
end

@testset "OhMyArtifacts.jl Basics" begin
    temp_pkg_dir() do project_dir
        # test init
        artifacts_toml = @my_artifacts_toml!()
        @test isdir(OhMyArtifacts.get_scratchspace())
        @test isdir(OhMyArtifacts.get_artifacts_dir())
        @test isfile(artifacts_toml)
        @test startswith(artifacts_toml, OhMyArtifacts.get_scratchspace())
        @test isempty(load_my_artifacts_toml(artifacts_toml))

        # test create for file
        hash_a = create_my_artifact() do artifact_dir
            cp(@__FILE__, joinpath(artifact_dir, "a"))
        end
        hash_b = create_my_artifact() do artifact_dir
            cp(joinpath(@__DIR__, "utils.jl"), joinpath(artifact_dir, "a"))
        end
        @test isfile(joinpath(OhMyArtifacts.get_artifacts_dir(), bytes2hex((hash_a.bytes[1],)), string(hash_a)))
        @test isfile(joinpath(OhMyArtifacts.get_artifacts_dir(), bytes2hex((hash_b.bytes[1],)), string(hash_b)))
        @test isfile(my_artifact_path(hash_a))
        @test isfile(my_artifact_path(hash_b))
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)

        # test bind for file
        bind_my_artifact!(artifacts_toml, "runtestfile", hash_a)
        bind_my_artifact!(artifacts_toml, "utils.jl", hash_b)
        @test length(load_my_artifacts_toml(artifacts_toml)) == 2
        @test my_artifact_hash("runtestfile", artifacts_toml) == hash_a
        @test my_artifact_hash("utils.jl", artifacts_toml) == hash_b

        # check usage is tracked correctly
        usagefile = OhMyArtifacts.usages_toml()
        @test isfile(usagefile)
        usage = OhMyArtifacts.parse_toml(usagefile)
        @test length(usage) == 2
        @test length(usage[my_artifact_path(hash_a)]) == 1
        @test length(usage[my_artifact_path(hash_b)]) == 1
        @test now() - usage[my_artifact_path(hash_a)][artifacts_toml]["runtestfile"] < Day(1)
        @test now() - usage[my_artifact_path(hash_b)][artifacts_toml]["utils.jl"] < Day(1)

        # test unbind: file won't be directly removed when unbind
        unbind_my_artifact!(artifacts_toml, "utils.jl")
        @test length(load_my_artifacts_toml(artifacts_toml)) == 1
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)

        # check orphan file is empty, not affected by unbind
        orphanfile = OhMyArtifacts.orphanages_toml()
        @test isfile(orphanfile)
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)

        # test find orphanages: not yet recycle
        OhMyArtifacts.find_orphanages()
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test length(orphan) == 1
        @test now() - orphan[my_artifact_path(hash_b)] < Day(1)
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)

        # test rebind correctly remove entry in orphan file
        bind_my_artifact!(artifacts_toml, "utils.jl", hash_b)
        OhMyArtifacts.find_orphanages()
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)

        # test recycle
        unbind_my_artifact!(artifacts_toml, "utils.jl")
        OhMyArtifacts.find_orphanages(; collect_delay=Hour(0))
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)
        @test my_artifact_exists(hash_a)
        @test !my_artifact_exists(hash_b)

        # test download
        url = "https://raw.githubusercontent.com/chengchingwen/OhMyArtifacts.jl/master/README.md"
        hash_c = download_my_artifact!(url, "readme", artifacts_toml)
        @test my_artifact_hash("readme", artifacts_toml) == hash_c
        @test my_artifact_exists(hash_c)
        @test isfile(my_artifact_path(hash_c))

        # test multiple usage
        another_toml = my_artifacts_toml!(Base.UUID("cf8be1f4-309d-442e-839d-29d2a0af6cb7"))
        @test isfile(another_toml)
        bind_my_artifact!(artifacts_toml, "runtests.jl", hash_a)
        bind_my_artifact!(another_toml, "runtests.jl", hash_a)
        usage = OhMyArtifacts.parse_toml(usagefile)
        @test length(usage) == 2
        @test length(usage[my_artifact_path(hash_a)]) == 2
        @test length(usage[my_artifact_path(hash_a)][artifacts_toml]) == 2
        @test length(usage[my_artifact_path(hash_c)]) == 1
    end

    temp_pkg_dir() do project_dir
        artifacts_toml = @my_artifacts_toml!()
        hash_a = create_my_artifact() do artifact_dir
            cp(@__FILE__, joinpath(artifact_dir, "a"))
        end
        hash_b = create_my_artifact() do artifact_dir
            cp(joinpath(@__DIR__, "utils.jl"), joinpath(artifact_dir, "a"))
        end

        # test bind on existing binding
        bind_my_artifact!(artifacts_toml, "A", hash_a)
        @test_throws ErrorException bind_my_artifact!(artifacts_toml, "A", hash_b)
        @test length(load_my_artifacts_toml(artifacts_toml)) == 1
        @test my_artifact_hash("A", artifacts_toml) == hash_a

        # test force bind
        bind_my_artifact!(artifacts_toml, "A", hash_b; force=true)
        @test length(load_my_artifacts_toml(artifacts_toml)) == 1
        @test my_artifact_hash("A", artifacts_toml) == hash_b

        # check usage file is not updated
        usagefile = OhMyArtifacts.usages_toml()
        usage = OhMyArtifacts.parse_toml(usagefile)
        @test length(usage) == 2
        @test length(usage[my_artifact_path(hash_a)]) == 1
        @test length(usage[my_artifact_path(hash_b)]) == 1

        # check orphan file is correct
        orphanfile = OhMyArtifacts.orphanages_toml()
        @test isfile(orphanfile)
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)

        # check orphan file and usage file is correctly updated after find orphanages
        OhMyArtifacts.find_orphanages()
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test length(orphan) == 1
        @test now() - orphan[my_artifact_path(hash_a)] < Day(1)
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
        usage = OhMyArtifacts.parse_toml(usagefile)
        @test length(usage) == 1
        @test !haskey(usage, my_artifact_path(hash_a))
        @test length(usage[my_artifact_path(hash_b)]) == 1

        # check recycle work correctly with force bind
        OhMyArtifacts.find_orphanages(; collect_delay=Hour(0))
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)
        @test !my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
    end

    temp_pkg_dir() do project_dir
        artifacts_toml = @my_artifacts_toml!()

        # test create folder: copy OhMyArtifacts docs folder
        hash_f = create_my_artifact() do working_dir
            path = joinpath(working_dir, "ohmy")
            cp(joinpath(dirname(@__DIR__), "docs"), path)
        end
        @test length(read_artifacts()) == 6

        hash_a = create_my_artifact() do artifact_dir
            cp(@__FILE__, joinpath(artifact_dir, "a"))
        end
        hash_b = create_my_artifact() do artifact_dir
            cp(joinpath(dirname(@__DIR__), "docs", "make.jl"), joinpath(artifact_dir, "a"))
        end
        @test length(read_artifacts()) == 7

        @test isfile(joinpath(OhMyArtifacts.get_artifacts_dir(), bytes2hex((hash_a.bytes[1],)), string(hash_a)))
        @test isfile(joinpath(OhMyArtifacts.get_artifacts_dir(), bytes2hex((hash_b.bytes[1],)), string(hash_b)))
        @test isdir(joinpath(OhMyArtifacts.get_artifacts_dir(), bytes2hex((hash_f.bytes[1],)), string(hash_f)))
        @test isfile(my_artifact_path(hash_a))
        @test isfile(my_artifact_path(hash_b))
        @test isdir(my_artifact_path(hash_f))
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
        @test my_artifact_exists(hash_f)

        # test bind for folder
        bind_my_artifact!(artifacts_toml, "ohmydocs", hash_f)
        bind_my_artifact!(artifacts_toml, "A", hash_a)
        bind_my_artifact!(artifacts_toml, "make", hash_b)

        @test length(load_my_artifacts_toml(artifacts_toml)) == 3
        @test my_artifact_hash("A", artifacts_toml) == hash_a
        @test my_artifact_hash("make", artifacts_toml) == hash_b
        @test my_artifact_hash("ohmydocs", artifacts_toml) == hash_f

        # check shadow folder
        @test list_folder(my_artifact_path(hash_f)) == list_folder(joinpath(dirname(@__DIR__), "docs"))

        # check usage is tracked correctly
        usagefile = OhMyArtifacts.usages_toml()
        @test isfile(usagefile)
        usage = OhMyArtifacts.parse_toml(usagefile)
        @test length(usage) == 7
        @test length(usage[my_artifact_path(hash_a)][artifacts_toml]) == 1
        @test length(usage[my_artifact_path(hash_b)][artifacts_toml]) == 2
        @test length(usage[my_artifact_path(hash_f)][artifacts_toml]) == 1
        @test now() - usage[my_artifact_path(hash_a)][artifacts_toml]["A"] < Day(1)
        @test now() - usage[my_artifact_path(hash_b)][artifacts_toml]["make"] < Day(1)
        @test now() - usage[my_artifact_path(hash_b)][artifacts_toml]["ohmydocs"] < Day(1)
        @test now() - usage[my_artifact_path(hash_f)][artifacts_toml]["ohmydocs"] < Day(1)

        # test unbind: file won't be directly removed when unbind
        unbind_my_artifact!(artifacts_toml, "ohmydocs")
        @test length(load_my_artifacts_toml(artifacts_toml)) == 2
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
        @test my_artifact_exists(hash_f)

        # check orphan file is empty, not affected by unbind
        orphanfile = OhMyArtifacts.orphanages_toml()
        @test isfile(orphanfile)
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)

        # test find orphanages: not yet recycle
        OhMyArtifacts.find_orphanages()
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test length(orphan) == 5
        @test !haskey(orphan, my_artifact_path(hash_b))
        @test now() - orphan[my_artifact_path(hash_f)] < Day(1)
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
        @test my_artifact_exists(hash_f)

        # test rebind correctly remove entry in orphan file
        bind_my_artifact!(artifacts_toml, "ohmydocs", hash_f)
        OhMyArtifacts.find_orphanages()
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)

        # test recycle
        unbind_my_artifact!(artifacts_toml, "ohmydocs")
        OhMyArtifacts.find_orphanages(; collect_delay=Hour(0))
        orphan = OhMyArtifacts.parse_toml(orphanfile)
        @test isempty(orphan)
        @test my_artifact_exists(hash_a)
        @test my_artifact_exists(hash_b)
        @test !my_artifact_exists(hash_f)
        @test length(read_artifacts()) == 2

    end
end
