using Test
using PortaPackage
using Pkg

using PortaPackage:
    _julia_filename,
    _latest_julia_url,
    _default_output_dir,
    _copy_project,
    _write_sh,
    _write_bat,
    _write_launcher

# ── Helpers ───────────────────────────────────────────────────────────────────

function make_project(name)
    parent = mktempdir()
    Pkg.generate(joinpath(parent, name))
    return joinpath(parent, name)
end

# Pre-seeding julia/ and depot/ causes _download_julia and _build_depot to
# return early (both check isdir(dest)), so no network or subprocess needed.
function preseed(out)
    mkpath(joinpath(out, "julia"))
    return mkpath(joinpath(out, "depot"))
end

# ─────────────────────────────────────────────────────────────────────────────
@testset "PortaPackage" begin

    # ── _julia_filename ───────────────────────────────────────────────────────
    # These tests verify the filename produced for the current host OS only,
    # since _julia_filename now uses Sys.is* rather than taking a Platform arg.
    @testset "_julia_filename" begin
        fname = _julia_filename("1.11.3")
        @test startswith(fname, "julia-1.11.3-")
        if Sys.islinux()
            @test endswith(fname, ".tar.gz")
            @test occursin("linux", fname)
        elseif Sys.isapple()
            @test endswith(fname, ".tar.gz")
            @test occursin("mac", fname)
        elseif Sys.iswindows()
            @test endswith(fname, ".zip")
            @test occursin("win", fname)
        end
    end

    # ── _latest_julia_url ─────────────────────────────────────────────────────
    @testset "_latest_julia_url" begin
        version, url = _latest_julia_url()

        @test occursin(r"^\d+\.\d+\.\d+$", version)
        @test startswith(url, "https://")
        @test occursin(version, url)
        if Sys.iswindows()
            @test endswith(url, ".zip")
        else
            @test endswith(url, ".tar.gz")
        end
    end

    # ── _default_output_dir ───────────────────────────────────────────────────
    @testset "_default_output_dir" begin
        dir = make_project("AwesomeApp")
        out = _default_output_dir(dir)
        @test basename(out) == "AwesomeApp-portable"
        @test dirname(out) == dirname(abspath(dir))
    end

    # ── _copy_project ─────────────────────────────────────────────────────────
    @testset "_copy_project" begin
        src = make_project("TestPkg")
        write(joinpath(src, "Manifest.toml"), "# manifest\n")

        dest = joinpath(mktempdir(), "copy")
        _copy_project(src, dest)

        @test isfile(joinpath(dest, "Project.toml"))
        @test isfile(joinpath(dest, "Manifest.toml"))
        @test isdir(joinpath(dest, "src"))
        @test isfile(joinpath(dest, "src", "TestPkg.jl"))

        # Re-copy overwrites without error
        _copy_project(src, dest)
        @test isfile(joinpath(dest, "Project.toml"))
    end

    # ── launcher scripts ──────────────────────────────────────────────────────
    @testset "launcher scripts" begin
        @testset "run.sh" begin
            path = joinpath(mktempdir(), "run.sh")
            _write_sh("MyApp", path)

            @test isfile(path)
            @test (filemode(path) & 0o111) != 0

            content = read(path, String)
            @test startswith(content, "#!/bin/sh")
            @test occursin("JULIA_DEPOT_PATH", content)
            @test occursin("julia/bin/julia", content)
            @test occursin("using MyApp; MyApp.main()", content)
            @test occursin("--startup-file=no", content)
            @test occursin("--project=", content)
            @test occursin("\$SCRIPT_DIR", content)
            @test occursin("\$@", content)
        end

        @testset "run.bat" begin
            path = joinpath(mktempdir(), "run.bat")
            _write_bat("MyApp", path)

            content = read(path, String)
            @test occursin("@echo off", content)
            @test occursin("JULIA_DEPOT_PATH", content)
            @test occursin("julia.exe", content)
            @test occursin("using MyApp; MyApp.main()", content)
            @test occursin("%SCRIPT_DIR%", content)
            @test occursin("%*", content)
        end

        @testset "_write_launcher writes run and pkg-named launchers" begin
            dir = mktempdir()
            _write_launcher("Foo", dir)
            if Sys.iswindows()
                @test isfile(joinpath(dir, "run.bat"))
                @test isfile(joinpath(dir, "Foo.bat"))
                @test !isfile(joinpath(dir, "run.sh"))
            else
                @test isfile(joinpath(dir, "run.sh"))
                @test isfile(joinpath(dir, "Foo.sh"))
                @test !isfile(joinpath(dir, "run.bat"))
            end
        end
    end

    # ── pack() ────────────────────────────────────────────────────────────────
    @testset "pack()" begin
        @testset "errors on missing Project.toml" begin
            @test_throws ErrorException pack(mktempdir())
        end

        @testset "errors on missing name field" begin
            dir = mktempdir()
            write(
                joinpath(dir, "Project.toml"),
                "uuid = \"00000000-0000-0000-0000-000000000001\"\n",
            )
            @test_throws ErrorException pack(dir)
        end

        @testset "output structure" begin
            src = make_project("HelloApp")
            out = mktempdir()
            preseed(out)

            result = pack(src; output_dir=out)

            @test result == out
            @test isdir(joinpath(out, "julia"))
            @test isdir(joinpath(out, "depot"))
            @test isdir(joinpath(out, "project"))
            @test isfile(joinpath(out, "project", "Project.toml"))
            if Sys.iswindows()
                @test isfile(joinpath(out, "run.bat"))
                @test isfile(joinpath(out, "HelloApp.bat"))
            else
                @test isfile(joinpath(out, "run.sh"))
                @test isfile(joinpath(out, "HelloApp.sh"))
                @test (filemode(joinpath(out, "run.sh")) & 0o111) != 0
                @test (filemode(joinpath(out, "HelloApp.sh")) & 0o111) != 0
            end
        end

        @testset "launcher references the correct package" begin
            src = make_project("SpecialTool")
            out = mktempdir()
            preseed(out)

            pack(src; output_dir=out)

            launcher = Sys.iswindows() ? joinpath(out, "run.bat") : joinpath(out, "run.sh")
            content = read(launcher, String)
            @test occursin("SpecialTool", content)
            @test occursin("SpecialTool.main()", content)
        end

        @testset "project files copied into bundle" begin
            src = make_project("CopyTest")
            write(joinpath(src, "Manifest.toml"), "# pinned manifest\n")
            out = mktempdir()
            preseed(out)

            pack(src; output_dir=out)

            proj_dir = joinpath(out, "project")
            @test isfile(joinpath(proj_dir, "Project.toml"))
            @test isfile(joinpath(proj_dir, "Manifest.toml"))
            @test isdir(joinpath(proj_dir, "src"))
        end

        @testset "default output_dir derived from package name" begin
            src = make_project("CoolTool")
            expected_out = joinpath(dirname(abspath(src)), "CoolTool-portable")
            preseed(expected_out)

            result = pack(src)

            @test result == expected_out
            @test isdir(joinpath(result, "project"))
            rm(expected_out; recursive=true, force=true)
        end
    end
end
