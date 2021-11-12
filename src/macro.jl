function cached_my_artifact_toml_path(mod::Module)
    sym = get_artifacts_toml_sym()
    !isdefined(mod, sym) && return nothing
    path = getfield(mod, sym)
    return (path isa Ref ? path[] : path)::String
end

function cached_my_artifact_toml_expr(mod::Module)
    sym = get_artifacts_toml_sym()
    !isdefined(mod, sym) && return nothing
    return quote
        path = getfield($mod, $(QuoteNode(sym)))
        (path isa Ref ? path[] : path)::String
    end
end

"""
    @my_artifact op name [hash]

Convenient macro for working with "Artifacts.toml". Requiring a global variable `my_artifacts` storing the path
 to "Artifacts.toml" (created by `@my_artifacts_toml!`) to work correctly.

Usage:

1. `@my_artifact :bind name hash` => `bind_my_artifact!(my_artifacts, name, hash)`
2. `@my_artifact :hash name` => `my_artifact_hash(name, my_artifacts)`
3. `@my_artifact :unbind name` => `unbind_my_artifact!(my_artifacts, name)`
4. `@my_artifact :download name url downloadf kwarg...` =>
    `download_my_artifact!(downloadf, url, name, my_artifacts; kwarg...)`

See also: [`bind_my_artifact!`](@ref), [`my_artifact_hash`](@ref),
 [`unbind_my_artifact!`](@ref), [`@my_artifacts_toml`](@ref)
"""
macro my_artifact(op, name, ex...)
    toml_path = cached_my_artifact_toml_expr(__module__)
    if isnothing(toml_path)
        error("no cached path for my artifact toml: $(__module__).$(get_artifacts_toml_sym()) undefined.")
    end

    if op == :bind || op == :(:bind)
        iszero(length(ex)) && error("wrong number of arguments for :bind, need \$name and \$hash.")
        hash = ex[1]
        kw_ex = Base.tail(ex)
        isempty(kw_ex) && return :(bind_my_artifact!($(toml_path), $(esc(name)), $(esc(hash))))

        !isone(length(kw_ex)) && error("wrong number of keyword arguments for :bind, only `force`")
        kw = kw_ex[1]
        bind_call = :(bind_my_artifact!($(toml_path), $(esc(name)), $(esc(hash)); ))
        kwargs = bind_call.args[2].args
        if kw == :force
            push!(kwargs, esc(kw))
        elseif kw isa Expr && kw.head == :(=)
            if kw.args[1] == :force
                kw.head = :kw
                push!(kwargs, esc(kw))
            else
                error("unknown keyword argument for :bind : $(kw.args[1])")
            end
        else
            error("weird keyword argument for :bind : $kw")
        end

        return bind_call
    elseif op == :hash || op == :(:hash)
        !iszero(length(ex)) && error("wrong number of arguments for :hash, need \$name.")
        return :(my_artifact_hash($(esc(name)), $(toml_path)))
    elseif op == :unbind || op == :(:unbind)
        !iszero(length(ex)) && error("wrong number of arguments for :unbind, need \$name.")
        return :(unbind_my_artifact!($(toml_path), $(esc(name))))
    elseif op == :download || op == :(:download)
        iszero(length(ex)) && error("wrong number of arguments for :download, need at least \$name and \$url")
        url = ex[1]
        if isone(length(ex))
            download_call = :(download_my_artifact!($(esc(url)), $(esc(name)), $(toml_path)))
        else
            downloadf = ex[2]
            if length(ex) == 2
                download_call = :(download_my_artifact!($(esc(downloadf)), $(esc(url)), $(esc(name)), $(toml_path)))
            else
                download_call = :(download_my_artifact!($(esc(downloadf)), $(esc(url)), $(esc(name)), $(toml_path); ))
                kwargs = download_call.args[2].args
                kw_ex = ex[3:end]
                for kw in kw_ex
                    if kw isa Symbol || (kw isa Expr && kw.head == :...)
                        push!(kwargs, esc(kw))
                    elseif kw isa Expr && kw.head == :(=)
                        kw.head = :kw
                        push!(kwargs, esc(kw))
                    else
                        error("weird keyword argument for downloadf: $kw")
                    end
                end
            end
        end

        return download_call
    else
        error("unknown artifact op: $op")
    end
end