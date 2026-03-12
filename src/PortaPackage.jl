module PortaPackage

using TOML
using Downloads

export pack

const JULIA_VERSIONS_URL = "https://julialang-s3.julialang.org/bin/versions.json"

# ── Main entry point ──────────────────────────────────────────────────────────

"""
    pack(project_path=pwd(); output_dir)

Create a portable distribution bundle of the Julia package at `project_path`
for the current host platform, using the latest stable Julia release.

The bundle includes:
- The Julia binary (latest stable, host platform)
- A self-contained depot with all package dependencies installed
- A launcher script that invokes `PackageName.main()`

# Arguments
- `project_path`: Path to the Julia project (default: current directory)
- `output_dir`: Where to write the bundle (default: `<name>-portable` next to project)

# Example
```julia
using PortaPackage
pack("/path/to/MyApp")
```
"""
function pack(
    project_path::String=pwd(); output_dir::String=_default_output_dir(project_path)
)
    project_path = abspath(project_path)
    toml_path = joinpath(project_path, "Project.toml")
    isfile(toml_path) || error("No Project.toml found at $project_path")

    project = TOML.parsefile(toml_path)
    pkg_name = get(project, "name", nothing)
    isnothing(pkg_name) && error("Project.toml missing a 'name' field")

    @info "Packing $pkg_name → $output_dir"
    mkpath(output_dir)

    _download_julia(joinpath(output_dir, "julia"))
    _copy_project(project_path, joinpath(output_dir, "project"))
    _build_depot(joinpath(output_dir, "project"), joinpath(output_dir, "depot"))
    _write_launcher(pkg_name, output_dir)

    @info "Done! Bundle written to: $output_dir"
    return output_dir
end

# ── Julia binary download ─────────────────────────────────────────────────────

"""
Return the expected archive filename for `version` on the current host platform.
Used to locate the right entry in versions.json.
"""
function _julia_filename(version::String)::String
    arch = string(Sys.ARCH)
    if Sys.islinux()
        return "julia-$version-linux-$arch.tar.gz"
    elseif Sys.isapple()
        return if arch == "x86_64"
            "julia-$version-mac64.tar.gz"
        else
            "julia-$version-mac$arch.tar.gz"
        end
    elseif Sys.iswindows()
        return Sys.WORD_SIZE == 64 ? "julia-$version-win64.zip" : "julia-$version-win32.zip"
    elseif Sys.isfreebsd()
        return "julia-$version-freebsd-$arch.tar.gz"
    else
        error("Unsupported OS")
    end
end

"""
Fetch versions.json and return `(version, url)` for the latest stable Julia
release available for the current host platform.
"""
function _latest_julia_url()::Tuple{String,String}
    buf = IOBuffer()
    Downloads.download(JULIA_VERSIONS_URL, buf)
    content = String(take!(buf))

    # Collect stable versions in one pass, then sort newest-first.
    versions = VersionNumber[]
    current_ver = nothing
    for line in split(content, '\n')
        m = match(r"""^\s*"(\d+\.\d+\.\d+)"\s*:""", line)
        if !isnothing(m)
            current_ver = m.captures[1]
            continue
        end
        if !isnothing(current_ver) && occursin(r""""stable"\s*:\s*true""", line)
            v = tryparse(VersionNumber, current_ver)
            !isnothing(v) && push!(versions, v)
            current_ver = nothing
        end
    end
    sort!(versions; rev=true)
    isempty(versions) && error("No stable Julia versions found in versions.json")

    # Walk newest-first, returning the first version that has a download for this host.
    for ver in versions
        version = string(ver)
        filename = _julia_filename(version)
        idx = findfirst(filename, content)
        isnothing(idx) && continue

        lo = max(1, idx.start - 300)
        hi = min(length(content), idx.start + 300)
        m = match(r"\"url\"\s*:\s*\"([^\"]+)\"", content[lo:hi])
        isnothing(m) && continue

        return version, m.captures[1]
    end

    return error("No stable Julia release found for the current platform")
end

"""
Download the latest stable Julia into `dest`.
Skips the download if `dest` already exists.
"""
function _download_julia(dest::String)
    if isdir(dest)
        @info "  Julia already present, skipping download"
        return nothing
    end

    version, url = _latest_julia_url()
    @info "  Downloading Julia $version"

    ext = endswith(url, ".zip") ? ".zip" : ".tar.gz"
    tmp = tempname() * ext
    try
        Downloads.download(url, tmp)
        _extract_archive(tmp, dest)
    finally
        rm(tmp; force=true)
    end
end

"""
Extract a `.tar.gz` or `.zip` archive into `dest`, stripping the top-level
`julia-x.y.z/` directory produced by Julia's official distributions.
"""
function _extract_archive(archive::String, dest::String)
    mktempdir() do tmp_dir
        if endswith(archive, ".tar.gz")
            run(`tar -xzf $archive -C $tmp_dir`)
        elseif endswith(archive, ".zip")
            if Sys.iswindows()
                run(
                    Cmd([
                        "powershell",
                        "-NoProfile",
                        "-Command",
                        "Expand-Archive -LiteralPath '$archive' -DestinationPath '$tmp_dir'",
                    ]),
                )
            else
                run(`unzip -q $archive -d $tmp_dir`)
            end
        else
            error("Unknown archive format: $archive")
        end

        entries = filter(readdir(tmp_dir; join=true)) do e
            isdir(e) && startswith(basename(e), "julia")
        end
        isempty(entries) && error("Could not find extracted Julia directory in $tmp_dir")
        mv(first(entries), dest)
    end
end

# ── Project copying ───────────────────────────────────────────────────────────

"""
Copy the essential project files (Project.toml, Manifest.toml, src/) to `dest`.
"""
function _copy_project(src::String, dest::String)
    isdir(dest) && rm(dest; recursive=true)
    mkpath(dest)
    for fname in ("Project.toml", "Manifest.toml")
        p = joinpath(src, fname)
        isfile(p) && cp(p, joinpath(dest, fname))
    end
    src_dir = joinpath(src, "src")
    return isdir(src_dir) && cp(src_dir, joinpath(dest, "src"))
end

# ── Depot building ────────────────────────────────────────────────────────────

"""
Build a self-contained depot at `depot_dir` by running `Pkg.instantiate()` with
`JULIA_DEPOT_PATH` pointed at the target directory.
Skips the build if `depot_dir` already exists.
"""
function _build_depot(project_dir::String, depot_dir::String)
    isdir(depot_dir) && return nothing

    julia_bin = joinpath(Sys.BINDIR, Sys.iswindows() ? "julia.exe" : "julia")
    isfile(julia_bin) || error("Julia binary not found: $julia_bin")

    script = """
    import Pkg
    Pkg.instantiate()
    Pkg.precompile()
    """

    # Build into a temp dir first: if the build fails, the isdir guard won't
    # mistake a partial depot for a successful one on the next run.
    tmp = mktempdir(dirname(depot_dir))
    try
        run(
            addenv(
                Cmd([
                    julia_bin, "--startup-file=no", "--project=$project_dir", "-e", script
                ]),
                "JULIA_DEPOT_PATH" => tmp,
                "JULIA_PKG_PRECOMPILE_AUTO" => "0",
            ),
        )
        mv(tmp, depot_dir)
    catch
        rm(tmp; recursive=true, force=true)
        rethrow()
    end
end

# ── Launcher scripts ──────────────────────────────────────────────────────────

function _write_launcher(pkg_name::String, dir::String)
    if Sys.iswindows()
        for name in ("run", pkg_name)
            _write_bat(pkg_name, joinpath(dir, "$name.bat"))
        end
    else
        for name in ("run", pkg_name)
            _write_sh(pkg_name, joinpath(dir, "$name.sh"))
        end
    end
end

function _write_sh(pkg_name::String, path::String)
    write(
        path,
        """#!/bin/sh
# Portable launcher for $pkg_name — generated by PortaPackage.jl
set -e
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
export JULIA_DEPOT_PATH="\$SCRIPT_DIR/depot"
exec "\$SCRIPT_DIR/julia/bin/julia" \\
    --startup-file=no \\
    --project="\$SCRIPT_DIR/project" \\
    -e 'using $pkg_name; $pkg_name.main()' \\
    "\$@"
""",
    )
    return chmod(path, 0o755)
end

function _write_bat(pkg_name::String, path::String)
    return write(
        path,
        """@echo off
rem Portable launcher for $pkg_name — generated by PortaPackage.jl
set "SCRIPT_DIR=%~dp0"
set "JULIA_DEPOT_PATH=%SCRIPT_DIR%depot"
"%SCRIPT_DIR%julia\\bin\\julia.exe" ^
    --startup-file=no ^
    --project="%SCRIPT_DIR%project" ^
    -e "using $pkg_name; $pkg_name.main()" ^
    %*
""",
    )
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function _default_output_dir(project_path::String)::String
    p = abspath(project_path)
    toml = joinpath(p, "Project.toml")
    name = isfile(toml) ? get(TOML.parsefile(toml), "name", basename(p)) : basename(p)
    return joinpath(dirname(p), name * "-portable")
end

end # module PortaPackage
