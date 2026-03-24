module PortaPackage

using Glob: glob
using DepotDelivery: build

# binary wrappers
using juliaup_jll

export download_julia, populate_depot

function pack(project_path, output_path; zip=true)
    # TODO: get app name from project_path/Project.toml
    # 
    mktempdir() do temp_depot_dir
        julia_path = download_julia(temp_depot_dir)
        populate_depot(project_path, temp_depot_dir)
        create_executable(app_name, temp_depot_dir, julia_path)
        # TODO copy temp_depot_dir contains into output_path
    end
    if zip
        # TODO handel zips using 7z, use same name as app_name, and save in project_dir/bin 
    end
end

"""
Uses juliaup to download a version of julia matching this one.
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
    matching_paths = glob("juliaup/julia-*/bin/julia", depot_dir)
    if isempty(matching_paths)
        error("Could not find julia binary")
    end
    julia_path = first(matching_paths)
    if !Sys.isexecutable(julia_path)
        error("Julia path found is not executable: $julia_path")
    end
    return relpath(julia_path, depot_dir)
end

"""
Uses DepotDelivery to populate the project depot at the desired path.
"""
function populate_depot(project_path, depot_dir)
    return build(project_path, depot_dir)
end

function get_shell_script(app_name, depot_dir, julia_path)
    return """
#!/bin/sh
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JULIA_DEPOT_PATH="\$DIR/$depot_dir"
"\$DIR/$julia_path" -m $app_name
"""
end

function get_bat_script(app_name, depot_dir, julia_path)
    # TODO replicate the above
    return """
"""
end

"""
Creates the corresponding executable file, depending on the system
"""
function create_executable(app_name, depot_dir, julia_path)
    if Sys.iswindows()
        # TODO replicate below
    else
        open(joinpath(depot_dir, "$app_name.sh"), "w") do f
            write(f, get_shell_script(app_name, depot_dir, julia_path))
        end
        # TODO make executable permissions
    end
    return nothing
end

end # module PortaPackage
