module PortaPackage

using Glob: glob
using DepotDelivery: build
using TOML

# binary wrappers
using juliaup_jll
using p7zip_jll

export pack

"""
Packs a Julia project into a portable, self-contained directory.
Downloads a matching Julia binary and populates a depot with all dependencies.
If `compress=true` (default), creates a zip archive in `project_path/bin/`.
If `output_path` is provided, copies the result there (after compression, if enabled).
Returns the zip path if compressing, otherwise `output_path`.
At least one of `output_path` or `compress=true` must be specified.
"""
function pack(project_path; output_path=nothing, compress=true)
    if isnothing(output_path) && !compress
        error("At least one of `output_path` or `compress=true` must be specified")
    end
    # get app name from Project.toml
    app_name = TOML.parsefile(joinpath(project_path, "Project.toml"))["name"]
    zip_path = nothing
    # create depot in a temp file,
    # this since we CANNOT do this in projec path,
    # otherwise we get recursive copying
    mktempdir() do temp_dir
        temp_depot_dir = joinpath(temp_dir, app_name)
        mkpath(temp_depot_dir)
        julia_path = download_julia(temp_depot_dir)
        populate_depot(project_path, temp_depot_dir)
        mkpath(joinpath(temp_depot_dir, "usr"))
        create_executable(app_name, temp_depot_dir, julia_path)
        create_install_script(app_name, temp_depot_dir, julia_path)
        update_startup_jl(temp_depot_dir)
        # compress first (from temp), then copy — avoids copying large dirs before compression
        if compress
            bin_dir = mkpath(joinpath(project_path, "bin"))
            zip_path = joinpath(bin_dir, "$app_name.zip")
            p7zip_exe = p7zip_jll.p7zip_path
            run(`$p7zip_exe a $zip_path $temp_depot_dir`)
        end
        if !isnothing(output_path)
            cp(temp_depot_dir, output_path; force=true)
        end
    end
    return compress ? zip_path : output_path
end

"""
Uses juliaup to download a version of julia matching this one.
Downloads into depot_dir
Returns the julia executable path, relative to the depot
"""
function download_julia(depot_dir)::AbstractString
    # setup depot
    depot_dir = abspath(depot_dir)
    if !ispath(depot_dir)
        mkpath(depot_dir)
    end
    # use juliaup to download julia
    juliaup_exe = juliaup_jll.juliaup_path
    withenv("JULIAUP_DEPOT_PATH" => depot_dir) do
        run(`$juliaup_exe add $VERSION`)
    end
    # find the executable path for julia
    julia_path = find_julia_path(depot_dir)
    return relpath(julia_path, depot_dir)
end

"""
Uses DepotDelivery to populate the project depot at the desired path.
"""
function populate_depot(project_path, depot_dir)
    return build(project_path, depot_dir)
end

function find_julia_path(depot_dir)
    matching_paths = if Sys.iswindows()
        glob("juliaup/julia-*/bin/julia.exe", depot_dir)
    else
        glob("juliaup/julia-*/bin/julia", depot_dir)
    end
    if isempty(matching_paths)
        error("Could not find julia binary")
    end
    julia_path = first(matching_paths)
    if !Sys.isexecutable(julia_path)
        error("Julia path found is not executable: $julia_path")
    end
    return julia_path
end

"""
Returns a shell scripts with correct paths and names
"""
function get_shell_script(app_name, julia_path)
    return """
#!/bin/sh
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JULIA_DEPOT_PATH="\$DIR"
export USER_DATA="\$DIR/usr"
"\$DIR/$julia_path" -m $app_name
"""
end

"""
Returns a bat scripts with correct paths and names
"""
function get_bat_script(app_name, julia_path)
    return """
@echo off
set DIR=%~dp0
set JULIA_DEPOT_PATH=%DIR%
set USER_DATA=%DIR%usr
"%DIR%$julia_path" -m $app_name
"""
end

"""
Creates the corresponding executable file, depending on the system.
Puts this file in the depot
"""
function create_executable(app_name, depot_dir, julia_path)
    if Sys.iswindows()
        open(joinpath(depot_dir, "$app_name.bat"), "w") do f
            write(f, get_bat_script(app_name, julia_path))
        end
    else
        script_path = joinpath(depot_dir, "$app_name.sh")
        open(script_path, "w") do f
            write(f, get_shell_script(app_name, julia_path))
        end
        chmod(script_path, 0o755)
    end
    return nothing
end

function update_startup_jl(depot_dir)
    config_dir = joinpath(depot_dir, "config")
    mkpath(config_dir)
    open(joinpath(config_dir, "startup.jl"), "w") do f
        write(f, "")
    end
end

"""
Returns a shell install script that runs Pkg.develop and Pkg.instantiate once.
"""
function get_install_sh_script(julia_path)
    return """
#!/bin/sh
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JULIA_DEPOT_PATH="\$DIR"
"\$DIR/$julia_path" "\$DIR/config/install.jl"
"""
end

"""
Returns a bat install script that runs Pkg.develop and Pkg.instantiate once.
"""
function get_install_bat_script(julia_path)
    return """
@echo off
set DIR=%~dp0
set JULIA_DEPOT_PATH=%DIR%
"%DIR%$julia_path" "%DIR%config\\install.jl"
"""
end

"""
Creates install.sh (or install.bat on Windows) and config/install.jl.
The user runs this once to set up the package before first use.
"""
function create_install_script(app_name, depot_dir, julia_path)
    config_dir = joinpath(depot_dir, "config")
    mkpath(config_dir)
    open(joinpath(config_dir, "install.jl"), "w") do f
        write(
            f,
            """
using Pkg
Pkg.develop("$app_name")
Pkg.instantiate()
""",
        )
    end
    if Sys.iswindows()
        open(joinpath(depot_dir, "$(app_name)Install.bat"), "w") do f
            write(f, get_install_bat_script(julia_path))
        end
    else
        script_path = joinpath(depot_dir, "$(app_name)Install.sh")
        open(script_path, "w") do f
            write(f, get_install_sh_script(julia_path))
        end
        chmod(script_path, 0o755)
    end
end

# For debugging
export main
(@main)(args) = println("Hello packer!")

end # module PortaPackage
