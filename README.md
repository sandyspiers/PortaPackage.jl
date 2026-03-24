# PortaPackage

Bundles your Julia project into a portable,
self-contained directory — including a matching Julia binary and all dependencies.
Ships with a shell script (or `.bat` on Windows) that launches your app directly via `julia -m`.

## Usage

```julia
using PortaPackage

# just produce a zip in myproject/bin/
pack("path/to/myproject")

# copy the bundle to a directory, no zip
pack("path/to/myproject"; output_path="path/to/output", compress=false)

# do both
pack("path/to/myproject"; output_path="path/to/output")
```

Your project needs a `Project.toml` with a `name` field,
and should be runnable via `julia -m <name>`,
[(must have main entry point)](https://pkgdocs.julialang.org/dev/apps/).

## Limitations

- Targets the currently running Julia version — cross-version bundling isn't supported.
- The bundled binary is platform-specific, so you can't build for a different OS.

## Similar Packages

- `AppBundler.jl` does the same as this, but designed for GUI's, and comes with an installer that usually has to be signed.
- `PackageCompiler.jl`
