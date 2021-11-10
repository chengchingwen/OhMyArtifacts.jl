# code borrow from https://github.com/JuliaPackaging/Scratch.jl/blob/v1.1.0/test/utils.jl
maybe_io(io) = (; io = io)

function temp_pkg_dir(fn::Function; rm=true)
    old_load_path = copy(LOAD_PATH)
    old_depot_path = copy(DEPOT_PATH)
    old_home_project = Base.HOME_PROJECT[]
    old_active_project = Base.ACTIVE_PROJECT[]
    try
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        Base.HOME_PROJECT[] = nothing
        Base.ACTIVE_PROJECT[] = nothing
        withenv("JULIA_PROJECT" => nothing,
                "JULIA_LOAD_PATH" => nothing,
                "JULIA_PKG_DEVDIR" => nothing) do
            env_dir = mktempdir()
            depot_dir = mktempdir()
            try
                push!(LOAD_PATH, "@", "@v#.#", "@stdlib")
                push!(DEPOT_PATH, depot_dir)
                Pkg.develop(PackageSpec(path=dirname(@__DIR__)); maybe_io(pkgio)...)
                fn(env_dir)
            finally
                try
                    rm && Base.rm(env_dir; force=true, recursive=true)
                    rm && Base.rm(depot_dir; force=true, recursive=true)
                catch err
                    # Avoid raising an exception here as it will mask the original exception
                    println(Base.stderr, "Exception in finally: $(sprint(showerror, err))")
                end
            end
        end
    finally
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        append!(LOAD_PATH, old_load_path)
        append!(DEPOT_PATH, old_depot_path)
        Base.HOME_PROJECT[] = old_home_project
        Base.ACTIVE_PROJECT[] = old_active_project
    end
end

function with_active_project(fn, project)
    old_project = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = abspath(project)
    try
        fn()
    finally
        Base.ACTIVE_PROJECT[] = old_project
    end
end

function temp_project_file(uuid = nothing)
    project = joinpath(mktempdir(), "Project.toml")
    touch(project)
    if uuid !== nothing
        open(project, "w") do io
            println(io, "uuid = \"$(uuid)\"")
        end
    end
    return project
end
