using Test
using PortaPackage
using Pkg

using PortaPackage:
    _julia_filename,
    _latest_julia_url,
    _default_output_dir,
    _copy_project,
    _build_depot,
    _write_sh,
    _write_bat,
    _write_launcher

# ── Helpers ───────────────────────────────────────────────────────────────────

function make_project(name)
    parent = mktempdir()
    Pkg.generate(joinpath(parent, name))
    return joinpath(parent, name)
end

# Preseed plants a no-op fake julia binary so that _download_julia skips the
# network download and _build_depot runs but does nothing real.
function preseed(out)
    bin_dir = mkpath(joinpath(out, "julia", "bin"))
    fake = joinpath(bin_dir, Sys.iswindows() ? "julia.exe" : "julia")
    if Sys.iswindows()
        write(fake, "@echo off\r\n")
    else
        write(fake, "#!/bin/sh\nexit 0\n")
        chmod(fake, 0o755)
    end
    return out
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

        # abspath("." ) and abspath("..") can return paths with a trailing separator;
        # all three call forms must resolve to the same output directory.
        src_dir = mkpath(joinpath(dir, "src"))
        out_dot    = _default_output_dir(joinpath(dir, "."))
        out_dotdot = _default_output_dir(joinpath(src_dir, ".."))
        @test out_dot    == out
        @test out_dotdot == out
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

    # ── _build_depot ──────────────────────────────────────────────────────────
    @testset "_build_depot" begin
        @testset "errors if julia_bin not found" begin
            @test_throws ErrorException _build_depot(
                "/nonexistent/julia", mktempdir(), joinpath(mktempdir(), "depot")
            )
        end

        if !Sys.iswindows()
            # Use a fake julia binary that logs its arguments so we can inspect
            # the -e script without running a real Julia subprocess.
            function make_fake_julia(log_path)
                path = tempname()
                write(path, "#!/bin/sh\necho \"\$@\" > \"$log_path\"\n")
                chmod(path, 0o755)
                return path
            end

            @testset "precompile=true includes Pkg.precompile()" begin
                log = tempname()
                _build_depot(make_fake_julia(log), make_project("FakeApp1"), joinpath(mktempdir(), "depot"))
                @test occursin("Pkg.precompile()", read(log, String))
            end

            @testset "precompile=false excludes Pkg.precompile()" begin
                log = tempname()
                _build_depot(make_fake_julia(log), make_project("FakeApp2"), joinpath(mktempdir(), "depot"); precompile=false)
                content = read(log, String)
                @test occursin("Pkg.instantiate()", content)
                @test !occursin("Pkg.precompile()", content)
            end

            @testset "always runs even when depot already exists" begin
                log1 = tempname()
                log2 = tempname()
                project = make_project("AlwaysRun")
                depot_dir = joinpath(mktempdir(), "depot")

                _build_depot(make_fake_julia(log1), project, depot_dir)
                @test isfile(log1)

                _build_depot(make_fake_julia(log2), project, depot_dir)
                @test isfile(log2)
            end
        end
    end

    # ── launcher scripts ──────────────────────────────────────────────────────
    @testset "launcher scripts" begin
        @testset "run.sh" begin
            path = joinpath(mktempdir(), "run.sh")
            _write_sh("MyApp", path)

            @test isfile(path)
            @test Sys.isexecutable(path)

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
                @test Sys.isexecutable(joinpath(out, "run.sh"))
                @test Sys.isexecutable(joinpath(out, "HelloApp.sh"))
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

        @testset "precompile=false accepted without error" begin
            src = make_project("NoPCApp")
            out = mktempdir()
            preseed(out)
            result = pack(src; output_dir=out, precompile=false)
            @test result == out
            @test isdir(joinpath(out, "depot"))
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
