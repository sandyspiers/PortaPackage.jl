# PortaPackage.jl

Make any Julia package portable — no installation required on the target machine.

**Note: this package was entirely vibe-coded for a specific use case. It works for me, but it has not been stressed tested.**

## The problem

Distributing Julia programs is hard. Asking users to install Julia, set up depots, and manage environments creates friction. [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) can produce standalone apps, but compilation frequently fails for packages with complex dependencies or non-relocatable artifacts.

## The solution

PortaPackage bundles everything the target machine needs into a single directory:

| What                             | Where                                           |
| -------------------------------- | ----------------------------------------------- |
| Julia binary (the right version) | `julia/`                                        |
| All package dependencies         | `depot/`                                        |
| Your project's source files      | `project/`                                      |
| Launch scripts                   | `run.sh` + `MyApp.sh` / `run.bat` + `MyApp.bat` |

Two equivalent launchers are written — `run` and one named after your package — so users can invoke the bundle either way. Both set `JULIA_DEPOT_PATH` to the bundled depot and invoke `PackageName.main()`. No internet, no `julia` on PATH, no environment setup needed on the target.

## Requirements

Your package must define a `main()` function as the entry point:

```julia
module MyApp

function main()
    println("Hello from MyApp!")
end

end
```

## Usage

```julia
using PortaPackage

# Bundle the package in the current directory
pack()

# Bundle a specific package
pack("/path/to/MyApp")

# Specify a custom output location
pack("/path/to/MyApp"; output_dir="/tmp/MyApp-bundle")
```

`pack()` always targets the **current host platform** and bundles the **latest stable Julia release**. To produce a bundle for a different OS, run `pack()` on a machine running that OS.

## Output layout

```
MyApp-portable/
├── julia/          # Extracted Julia binary distribution
├── depot/          # Self-contained package depot (Pkg.instantiate'd)
├── project/        # Project.toml + Manifest.toml + src/
├── run.sh          # Generic launcher (Linux / macOS)
├── MyApp.sh        # Package-named launcher (Linux / macOS)
├── run.bat         # Generic launcher (Windows)
└── MyApp.bat       # Package-named launcher (Windows)
```

## How it works

1. **Download** — queries `versions.json` on julialang.org for the latest stable release, fetches the binary tarball/zip for the host platform, and extracts it into `julia/`.
2. **Copy** — copies `Project.toml`, `Manifest.toml`, and `src/` into `project/`.
3. **Depot** — runs `Pkg.instantiate()` + `Pkg.precompile()` with `JULIA_DEPOT_PATH` pointed at `depot/`, pulling all dependencies into the bundle.
4. **Launchers** — writes two shell/batch scripts (`run` and `MyApp`) that set `JULIA_DEPOT_PATH` and `exec` the bundled Julia with `-e 'using MyApp; MyApp.main()'`.
