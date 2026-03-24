using Test
using PortaPackage

@testset "get_shell_script" begin
    script = PortaPackage.get_shell_script("MyApp", "juliaup/julia-1.x/bin/julia")
    @test contains(script, "#!/bin/sh")
    @test contains(script, "MyApp")
    @test contains(script, "juliaup/julia-1.x/bin/julia")
    @test contains(script, "JULIA_DEPOT_PATH=\"\$DIR\"")
end

@testset "get_bat_script" begin
    script = PortaPackage.get_bat_script("MyApp", "juliaup/julia-1.x/bin/julia.exe")
    @test contains(script, "@echo off")
    @test contains(script, "MyApp")
    @test contains(script, "juliaup/julia-1.x/bin/julia.exe")
    @test contains(script, "JULIA_DEPOT_PATH=%DIR%")
end

@testset "pack argument validation" begin
    @test_throws ErrorException pack("myproject"; output_path=nothing, compress=false)
end

@testset "create_executable" begin
    mktempdir() do depot_dir
        PortaPackage.create_executable("MyApp", depot_dir, "bin/julia")
        if Sys.iswindows()
            bat_path = joinpath(depot_dir, "MyApp.bat")
            @test isfile(bat_path)
            @test contains(read(bat_path, String), "@echo off")
        else
            sh_path = joinpath(depot_dir, "MyApp.sh")
            @test isfile(sh_path)
            @test contains(read(sh_path, String), "#!/bin/sh")
            @test Sys.isexecutable(sh_path)
        end
    end
end
