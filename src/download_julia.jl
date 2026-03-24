function download_julia(; ver=VERSION, depot_path)
    juliaup = juliaup_jll.juliaup_path()
    exe = `$juliaup add $ver`
    withenv("JULIA_DEPOT" => depot_path) do
        run(exe)
    end
    return true
end
