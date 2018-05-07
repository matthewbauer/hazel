# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Skylark build rules for cabal haskell packages.

To see all of the generated rules, run:
bazel query --output=build @haskell_{package}//:all
"""
load("@bazel_skylib//:lib.bzl", "paths")
load("@io_tweag_rules_haskell//haskell:haskell.bzl",
     "haskell_library",
     "haskell_binary")
load("//:alex.bzl", "genalex")
load("//:cabal_paths.bzl", "cabal_paths")
load("//:happy.bzl", "genhappy")

_conditions_default = "//conditions:default"

# Cabal macro generation target name ends with this.
_macros_suffix = "-macros"

# Template files that we should install manually for Happy and Alex
# TODO: figure out a better bootstrapping method
_MANUAL_DATA_FILES = {
    "happy": [
      "GLR_Base",
      "HappyTemplate-arrays-coerce-debug",
      "GLR_Lib",
      "HappyTemplate-arrays-debug",
      "GLR_Lib-ghc",
      "HappyTemplate-arrays-ghc",
      "GLR_Lib-ghc-debug",
      "HappyTemplate-arrays-ghc-debug",
      "HappyTemplate",
      "HappyTemplate-coerce",
      "HappyTemplate-arrays",
      "HappyTemplate-ghc",
      "HappyTemplate-arrays-coerce",
    ],
    "alex": [
      "AlexTemplate",
      "AlexTemplate-debug",
      "AlexTemplate-ghc",
      "AlexTemplate-ghc-debug",
      "AlexTemplate-ghc-nopred",
      "AlexWrapper-basic",
      "AlexWrapper-basic-bytestring",
      "AlexWrapper-gscan",
      "AlexWrapper-monad",
      "AlexWrapper-monad-bytestring",
      "AlexWrapper-monadUserState",
      "AlexWrapper-monadUserState-bytestring",
      "AlexWrapper-posn",
      "AlexWrapper-posn-bytestring",
      "AlexWrapper-strict-bytestring",
    ],
}

# The _cabal_haskell_macros rule generates a file containing Cabal
# MIN_VERSION_* macros of all of the specified dependencies, as well as some
# other Cabal macros.
# For more details, see //bzl/cabal/GenerateCabalMacros.hs.
# Args:
#   deps: A list of cabal_haskell_library rules.
#   default_packages: A list of names of default packages that
#     this package depends on; e.g., "base".
def _impl_cabal_haskell_macros(ctx):
  if not ctx.label.name.endswith(_macros_suffix):
    fail("Macros target ends with unexpected suffix.")
  ctx.action(
      outputs=[ctx.outputs.out],
      inputs=[ctx.executable._generate_cabal_macros],
      progress_message="Generating Haskell Cabal macros for %s" % str(ctx.label),
      mnemonic="HaskellGenerateCabalMacros",
      command=(
          " ".join(
              [ctx.executable._generate_cabal_macros.path]
              + ["{}-{}".format(p, ctx.attr.packages[p])
                 for p in ctx.attr.packages])
          + " > " + ctx.outputs.out.path),
  )

_cabal_haskell_macros = rule(
    implementation=_impl_cabal_haskell_macros,
    attrs={
        "packages": attr.string_dict(mandatory=True),
        "_generate_cabal_macros": attr.label(
            executable=True,
            cfg="host",
            allow_files=True,
            single_file=True,
            default=Label("@hazel_base_repository//:generate-cabal-macros")
        ),
    },
    outputs={"out": "%{name}.h"},
)

def _paths_module(desc):
  return "Paths_" + desc.package.pkgName.replace("-","_")

def _hazel_symlink_impl(ctx):
  ctx.actions.run(
      outputs=[ctx.outputs.out],
      inputs=[ctx.file.src],
      executable="ln",
      arguments=["-s",
                  "/".join([".."] * len(ctx.outputs.out.dirname.split("/")))
                    + "/" + ctx.file.src.path,
                  ctx.outputs.out.path])

hazel_symlink = rule(
    implementation = _hazel_symlink_impl,
    attrs = {
        "src": attr.label(mandatory=True, allow_files=True, single_file=True),
        "out": attr.string(mandatory=True),
    },
    outputs={"out": "%{out}"})

def _glob_modules(src_dir, extension, out_extension):
  """List Haskell files under the given directory with this extension.

  Args:
    src_dir: A subdirectory relative to this package.
    extension: A file extension; for example, ".hs" or ".hsc".
  Returns:
    A list of 3-tuples containing:
      1. The original file, e.g., "srcs/Foo/Bar.hsc"
      2. The Haskell module name, e.g., "Foo.Bar"
      3. The preprocessed Haskell file name, e.g., "Foo/Bar.hs"
  """
  outputs = []
  for f in native.glob([paths.normalize(paths.join(src_dir, "**", "*" + extension))]):
    m,_ = paths.split_extension(paths.relativize(f, src_dir))
    outputs += [(f, m.replace("/", "."), m + out_extension)]
  return outputs

def _conditions_dict(d):
  return d.select if hasattr(d, "select") else {_conditions_default: d}

def _fix_source_dirs(dirs):
  if dirs:
    return dirs
  return [""]

def _get_build_attrs(name, build_info, desc, generated_srcs_dir, extra_modules,
                     prebuilt_dependencies, packages,
                     cc_deps=[], version_overrides=None, ghcopts=[]):
  """Get the attributes for a particular library or binary rule.

  Args:
    name: The name of this component.
    build_info: A struct of the Cabal BuildInfo for this component.
    desc: A struct of the Cabal PackageDescription for this package.
    generated_srcs_dir: Location of autogenerated files for this rule,
      e.g., "dist/build" for libraries.
    extra_modules: exposed-modules: or other-modules: in the package description
    cc_deps: External cc_libraries that this rule should depend on.
    version_overrides: Override the default version of specific dependencies;
      see cabal_haskell_package for more details.
    ghcopts: Extra GHC options.
  Returns:
    A dictionary of attributes (e.g. "srcs", "deps") that can be passed
    into a haskell_library or haskell_binary rule.
  """

  # Preprocess and collect all the source files by their extension.
  # module_map will contain a dictionary from module names ("Foo.Bar")
  # to the preprocessed source file ("src/Foo/Bar.hs").
  module_map = {}
  boot_module_map = {}

  srcs_dir = "gen-srcs/"

  for d in _fix_source_dirs(build_info.hsSourceDirs) + [generated_srcs_dir]:
    for f,m,out in _glob_modules(d, ".x", ".hs"):
      module_map[m] = srcs_dir + out
      genalex(
          src = f,
          out = module_map[m],
      )
    for f,m,out in _glob_modules(d, ".y", ".hs") + _glob_modules(d, ".ly", ".hs"):
      module_map[m] = srcs_dir + out
      genhappy(
          src = f,
          out = module_map[m],
      )
    # Raw source files.  Include them last, to override duplicates (e.g. if a
    # package contains both a Happy Foo.y file and the corresponding generated
    # Foo.hs).
    for f,m,out in (_glob_modules(d, ".hs", ".hs")
                     + _glob_modules(d, ".lhs", ".lhs")
                     + _glob_modules(d, ".hsc", ".hsc")):
      if m not in module_map:
        module_map[m] = srcs_dir + out
        hazel_symlink(
            name = name + "-" + m,
            src = f,
            out = module_map[m],
        )
    for f,m,out in (_glob_modules(d, ".hs-boot", ".hs-boot")
                     + _glob_modules(d, ".lhs-boot", ".lhs-boot")):
      boot_module_map[m] = srcs_dir + out
      hazel_symlink(
          name = name + "-boot-" + m,
          src = f,
          out = boot_module_map[m],
      )


  print("BOOT", boot_module_map)



  # Collect the source files for each module in this Cabal component.
  # srcs is a mapping from "select()" conditions (e.g. //third_party/haskell/ghc:ghc-8.0.2) to a list of source files.
  # Turn "boot_srcs" and others to dicts if there is a use case.
  srcs = {}
  # Keep track of .hs-boot files specially.  GHC doesn't want us to pass
  # them as command-line arguments; instead, it looks for them next to the
  # corresponding .hs files.
  boot_srcs = []
  deps = {}
  paths_module = _paths_module(desc)
  extra_modules_dict = _conditions_dict(extra_modules)
  other_modules_dict = _conditions_dict(build_info.otherModules)
  for condition in depset(extra_modules_dict.keys() + other_modules_dict.keys()):
    srcs[condition] = []
    deps[condition] = []
    for m in (extra_modules_dict.get(condition, []) +
              other_modules_dict.get(condition, [])):
      if m == paths_module:
        deps[condition] += [":" + paths_module]
      elif m in module_map:
        srcs[condition] += [module_map[m]]
        # Get ".hs-boot" and ".lhs-boot" files.
        if m in boot_module_map:
          print("BOOT!!!", m, boot_module_map[m])
          srcs[condition] += [boot_module_map[m]]
        else:
          print("NOBOOT", name, m)
      else:
        fail("Missing module %s for %s" % (m, name) + str(module_map))

  # Collect the options to pass to ghc.
  extra_ghcopts = ghcopts
  ghcopts = []
  all_extensions = [ ext for ext in
                     ([build_info.defaultLanguage]
                      if build_info.defaultLanguage else ["Haskell98"])
                     + build_info.defaultExtensions
                     + build_info.oldExtensions ]
  ghcopts = ghcopts + ["-X" + ext for ext in all_extensions]

  ghcopt_blacklist = ["-Wall","-Wwarn","-w","-Werror", "-O2", "-O", "-O0"]
  for (compiler,opts) in build_info.options:
    if compiler == "ghc":
      ghcopts += [o for o in opts if o not in ghcopt_blacklist]
  ghcopts += ["-w", "-Wwarn"]  # -w doesn't kill all warnings...

  # Collect the dependencies.
  prebuilt_deps = []
  dep_versions = {}
  explicit_deps_idx = len(deps[_conditions_default])
  for condition, ps in _conditions_dict(build_info.targetBuildDepends).items():
    if condition not in deps:
      deps[condition] = []
    for p in ps:
      if p.name in prebuilt_dependencies:
        dep_versions[p.name] = prebuilt_dependencies[p.name]
        prebuilt_deps += [p.name]
      elif p.name == desc.package.pkgName:
        # Allow executables to depend on the library in the same package.
        deps[condition] += [":" + p.name]
      else:
        deps[condition] += ["@haskell_{}//:{}-lib".format(p.name, p.name)]
        dep_versions[p.name] = packages[p.name]


  # Generate the macros for these dependencies.
  # TODO: Maybe remove the MIN_VERSION_<package> macro generation,
  #   since GHC 8 itself (not Cabal) generates these. But not the
  #   CURRENT_PACKAGE_KEY macro?
  #   See https://ghc.haskell.org/trac/ghc/ticket/10970.
  _cabal_haskell_macros(
      name = name + _macros_suffix,
      packages = dep_versions,
  )
  ghcopts += ["-optP-include", "-optP%s.h" % (name + _macros_suffix)]

  ghcopts += ["-optP" + o for o in build_info.cppOptions]

  # Generate a cc_library for this package.
  # TODO(judahjacobson): don't create the rule if it's not needed.
  # TODO(judahjacobson): Figure out the corner case logic for some packages.
  # In particular: JuicyPixels, cmark, ieee754.
  install_includes = native.glob(
      [paths.join(d, f) for d in build_info.includeDirs
       for f in build_info.installIncludes])
  headers = depset(
      native.glob(desc.extraSrcFiles)
      + install_includes
      + [":{}.h".format(name + _macros_suffix)])
  ghcopts += ["-I" + native.package_name() + "/" + d for d in build_info.includeDirs]
  lib_name = name + "-cbits"
  for xs in deps.values():
    xs.append(":" + lib_name)
  native.cc_library(
      name = lib_name,
      srcs = build_info.cSources,
      includes = build_info.includeDirs,
      copts = ([o for o in build_info.ccOptions if not o.startswith("-D")]
               + ["-w"]),
      defines = [o[2:] for o in build_info.ccOptions if o.startswith("-D")],
      textual_hdrs = list(headers),
      deps = ["@ghc//:threaded-rts"] + cc_deps,
  )

  return {
      "srcs": srcs,
      "deps": deps,
      "prebuilt_dependencies": prebuilt_deps,
      "compiler_flags": ghcopts + extra_ghcopts,
      "src_strip_prefix": srcs_dir,
  }

def _collect_data_files(description):
  name = description.package.pkgName
  if name in _MANUAL_DATA_FILES:
    files = []
    for f in _MANUAL_DATA_FILES[name]:
      out = paths.join(description.dataDir, f)
      hazel_symlink(
          name = name + "-template-" + f,
          src = "@ai_formation_hazel//templates/" + name + ":" + f,
          out = out)
      files += [out]
    return files
  else:
    return native.glob([paths.join(description.dataDir, d) for d in description.dataFiles])

def cabal_haskell_package(description, prebuilt_dependencies, packages):
  name = description.package.pkgName

  cabal_paths(
      name = _paths_module(description),
      package = name.replace("-","_"),
      version = [int(v) for v in description.package.pkgVersion.split(".")],
      data_dir = description.dataDir,
      data = _collect_data_files(description),
  )

  lib = description.library
  if lib and lib.libBuildInfo.buildable:
    lib_name = name + "-lib"
    if not lib.exposedModules:
      native.cc_library(
          name = lib_name,
          visibility = ["//visibility:public"],
      )
    else:
      lib_attrs = _get_build_attrs(name + "-lib", lib.libBuildInfo, description,
                                   "dist/build",
                                   lib.exposedModules,
                                   prebuilt_dependencies,
                                   packages)
      srcs = lib_attrs.pop("srcs")
      deps = lib_attrs.pop("deps")
      haskell_library(
          name = lib_name,
          srcs = select(srcs),
          deps = select(deps),
          visibility = ["//visibility:public"],
          **lib_attrs
      )

  for exe in description.executables:
    if not exe.buildInfo.buildable:
      continue
    exe_name = exe.exeName
        # Avoid a name clash with the library.  For stability, make this logic
    # independent of whether the package actually contains a library.
    if exe_name == name:
      exe_name = name + "_bin"
    paths_mod = _paths_module(description)
    attrs = _get_build_attrs(exe_name, exe.buildInfo, description,
                             "dist/build/%s/%s-tmp" % (name, name),
                             # Some packages (e.g. happy) don't specify the
                             # Paths_ module explicitly.
                             [paths_mod] if paths_mod not in exe.buildInfo.otherModules
                                        else [],
                             prebuilt_dependencies,
                             packages)
    srcs = attrs.pop("srcs")
    deps = attrs.pop("deps")

    [full_module_path] = native.glob(
        [paths.join(d, exe.modulePath) for d in exe.buildInfo.hsSourceDirs])
    full_module_out = paths.join(attrs["src_strip_prefix"], full_module_path)
    for xs in srcs.values():
      if full_module_out not in xs:
        hazel_symlink(
            name = exe_name + "-" + exe.modulePath,
            src = full_module_path,
            out = full_module_out)
        xs.append(full_module_out)

    haskell_binary(
        name = exe_name,
        srcs = select(srcs),
        main_file = full_module_out,
        deps = select(deps),
        visibility = ["//visibility:public"],
        **attrs
    )
