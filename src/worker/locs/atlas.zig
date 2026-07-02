//! The SOURCE ATLAS — curated, compiled-in seed locations for knowledge domains.

const std = @import("std");

pub const Kind = enum { reference, tutorial, spec, cookbook, index };

pub const Loc = struct {
    name: []const u8, // short domain label, shown in the directive block
    tags: []const []const u8, // word-bounded match keys against gap/goal text (multi-word tags allowed)
    seeds: []const []const u8, // canonical entry urls — DOC ROOTS, not homepages; static/curl-friendly only
    kind: Kind = .reference,
    depth: u8 = 2, // suggested crawl depth from a seed
    trust: f32 = 1.0, // ranking prior only — LEARNED application-trust decides what survives
    pack: []const u8 = "", // nl-rag PACK index url — pre-normalized AI markdown (fetch-first when set)
};

/// nl-rag (github.com/gary23w/nl-rag) mirrors curated doc pages as pre-normalized markdown packs:
/// no HTML, no site chrome, frontmattered provenance, split to fetch-sized parts. For a small model
/// that's strictly better input than the raw doc site, and raw.githubusercontent bodies ride the
/// existing 7-day fetch cache — so a pack page costs one GET ever. The INDEX lists every page of the
/// pack (plus a distilled pack.facts) as absolute raw urls. Seeds stay listed: the pack is a fast
/// mirror, not a replacement, and freshness-critical topics should still hit the origin.
fn packUrl(comptime domain: []const u8) []const u8 {
    return "https://raw.githubusercontent.com/gary23w/nl-rag/main/packs/" ++ domain ++ "/INDEX.md";
}

/// Curation rules: (1) official documentation first; (2) the url must serve real HTML to curl (no
/// JS-walled apps); (3) doc roots over homepages so depth-2 crawls land on content; (4) tags must survive
/// word-bounded matching — never a tag that is a common English word ("go", "c") — use "golang",
/// "c language". A bare plural in the text still hits its singular tag (trailing-'s' tolerance).
/// (5) a common dev word that spans many tools never tags one tool ("debugging" is not GDB, "chart" is
/// not matplotlib) — anchor it to the domain ("gdb debugging", "matplotlib chart") so unrelated task
/// prose can't false-route. Everything past the base block came from a live-curl-verified curation pass
/// (every seed answered 200 with real static HTML) followed by a tag-safety audit applying rule (5).
pub const ATLAS = [_]Loc{
    // — base block: the original hand-curated core; listed first so score ties resolve toward it —
    .{ .name = "python", .pack = packUrl("python"), .tags = &.{ "python", "pytest", "cpython", "pip" }, .seeds = &.{ "https://docs.python.org/3/library/", "https://docs.python.org/3/tutorial/", "https://docs.pytest.org/en/stable/" } },
    .{ .name = "rust", .pack = packUrl("rust"), .tags = &.{ "rust", "cargo", "borrow checker", "rustc" }, .seeds = &.{ "https://doc.rust-lang.org/std/", "https://doc.rust-lang.org/book/", "https://doc.rust-lang.org/rust-by-example/" } },
    .{ .name = "ruby", .pack = packUrl("ruby"), .tags = &.{ "ruby", "rails", "rubygem" }, .seeds = &.{ "https://ruby-doc.org/core/", "https://ruby-doc.org/stdlib/", "https://guides.rubyonrails.org/" } },
    .{ .name = "golang", .pack = packUrl("golang"), .tags = &.{ "golang", "goroutine", "go module", "go stdlib" }, .seeds = &.{ "https://go.dev/doc/", "https://pkg.go.dev/std", "https://go.dev/ref/spec" } },
    .{ .name = "javascript", .pack = packUrl("javascript"), .tags = &.{ "javascript", "node.js", "nodejs", "npm" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/JavaScript", "https://nodejs.org/api/" } },
    .{ .name = "web-platform", .pack = packUrl("web-platform"), .tags = &.{ "html", "css", "dom", "frontend" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/HTML", "https://developer.mozilla.org/en-US/docs/Web/CSS" } },
    .{ .name = "http-rest", .pack = packUrl("http-rest"), .tags = &.{ "http", "rest api", "endpoint", "cookie", "cors" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/HTTP", "https://www.rfc-editor.org/rfc/rfc9110.html" }, .kind = .spec },
    .{ .name = "sql-sqlite", .pack = packUrl("sql-sqlite"), .tags = &.{ "sql", "sqlite", "database schema" }, .seeds = &.{ "https://sqlite.org/lang.html", "https://sqlite.org/docs.html" } },
    .{ .name = "zig", .pack = packUrl("zig"), .tags = &.{ "zig", "comptime" }, .seeds = &.{ "https://ziglang.org/documentation/master/", "https://ziglang.org/documentation/master/std/" } },
    .{ .name = "algorithms", .pack = packUrl("algorithms"), .tags = &.{ "algorithm", "sorting", "complexity", "big-o", "dynamic programming" }, .seeds = &.{ "https://en.wikipedia.org/wiki/List_of_algorithms", "https://en.wikipedia.org/wiki/Analysis_of_algorithms" }, .kind = .index, .trust = 0.8 },
    .{ .name = "data-structures", .pack = packUrl("data-structures"), .tags = &.{ "data structure", "hash table", "binary tree", "linked list", "b-tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/List_of_data_structures"}, .kind = .index, .trust = 0.8 },
    .{ .name = "software-design", .pack = packUrl("software-design"), .tags = &.{ "design pattern", "software architecture", "software design", "refactoring" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Software_design_pattern", "https://refactoring.guru/design-patterns" }, .kind = .cookbook, .trust = 0.8 },
    .{ .name = "security", .pack = packUrl("security"), .tags = &.{ "security", "authentication", "password hashing", "session token", "owasp" }, .seeds = &.{ "https://cheatsheetseries.owasp.org/", "https://en.wikipedia.org/wiki/PBKDF2" }, .kind = .cookbook, .trust = 0.9 },
    .{ .name = "git", .pack = packUrl("git"), .tags = &.{ "git", "merge conflict", "version control" }, .seeds = &.{"https://git-scm.com/docs"} },
    .{ .name = "shell-linux", .pack = packUrl("shell-linux"), .tags = &.{ "bash", "shell script", "linux command", "posix" }, .seeds = &.{ "https://www.gnu.org/software/bash/manual/bash.html", "https://man7.org/linux/man-pages/" } },
    .{ .name = "regex", .pack = packUrl("regex"), .tags = &.{ "regex", "regular expression" }, .seeds = &.{"https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_expressions"} },

    // — systems languages & native toolchains —
    .{ .name = "c-language", .pack = packUrl("c-cpp"), .tags = &.{ "c language", "c programming", "c standard library", "libc", "c11" }, .seeds = &.{ "https://en.cppreference.com/w/c", "https://en.cppreference.com/w/c/language" } },
    .{ .name = "cpp-language", .pack = packUrl("c-cpp"), .tags = &.{ "c++", "cpp", "c++ stl", "cppreference", "modern c++", "clang" }, .seeds = &.{ "https://en.cppreference.com/w/cpp", "https://en.cppreference.com/w/cpp/language" } },
    .{ .name = "x86-assembly", .pack = packUrl("x86-assembly"), .tags = &.{ "x86 assembly", "assembly language", "x86", "x86-64", "amd64", "asm" }, .seeds = &.{ "https://www.felixcloutier.com/x86/", "https://en.wikipedia.org/wiki/X86_instruction_listings" }, .trust = 0.9 },
    .{ .name = "gnu-make", .pack = packUrl("build-systems"), .tags = &.{ "makefile", "gnu make", "gmake", "makefile rules" }, .seeds = &.{ "https://www.gnu.org/software/make/manual/html_node/index.html", "https://www.gnu.org/software/make/manual/" } },
    .{ .name = "cmake", .pack = packUrl("build-systems"), .tags = &.{ "cmake", "cmakelists", "ctest", "cpack" }, .seeds = &.{ "https://cmake.org/cmake/help/latest/", "https://cmake.org/cmake/help/latest/guide/tutorial/index.html" } },
    .{ .name = "gdb-debugging", .pack = packUrl("gdb-debugging"), .tags = &.{ "gdb", "gdb debugging", "gdb debugger", "gdb breakpoint", "core dump" }, .seeds = &.{"https://sourceware.org/gdb/current/onlinedocs/gdb/"} },
    .{ .name = "perl-docs", .pack = packUrl("perl-docs"), .tags = &.{ "perl", "perldoc", "perl script", "perl module", "cpan" }, .seeds = &.{ "https://perldoc.perl.org/", "https://perldoc.perl.org/perlintro", "https://perldoc.perl.org/functions" } },
    .{ .name = "lua", .pack = packUrl("lua"), .tags = &.{ "lua", "lua scripting", "lua manual", "programming in lua" }, .seeds = &.{ "https://www.lua.org/manual/5.4/", "https://www.lua.org/docs.html", "https://www.lua.org/pil/contents.html" } },
    .{ .name = "php-manual", .pack = packUrl("php-manual"), .tags = &.{ "php", "php manual", "php function", "php script" }, .seeds = &.{ "https://www.php.net/manual/en/", "https://www.php.net/manual/en/langref.php", "https://www.php.net/manual/en/funcref.php" } },

    // — jvm & .net —
    .{ .name = "java", .pack = packUrl("java"), .tags = &.{ "java", "jdk", "javase", "jvm" }, .seeds = &.{ "https://dev.java/learn/", "https://docs.oracle.com/javase/specs/", "https://docs.oracle.com/en/java/javase/21/docs/api/index.html" } },
    .{ .name = "kotlin", .pack = packUrl("kotlin"), .tags = &.{ "kotlin", "kotlinlang", "kotlin multiplatform" }, .seeds = &.{ "https://kotlinlang.org/docs/home.html", "https://kotlinlang.org/docs/basic-syntax.html" } },
    .{ .name = "scala", .pack = packUrl("scala"), .tags = &.{ "scala", "scala 3", "sbt" }, .seeds = &.{ "https://docs.scala-lang.org/", "https://docs.scala-lang.org/scala3/book/introduction.html" } },
    .{ .name = "clojure", .pack = packUrl("clojure"), .tags = &.{ "clojure", "clojurescript", "leiningen" }, .seeds = &.{ "https://clojure.org/reference/reader", "https://clojure.org/api/cheatsheet" } },
    .{ .name = "csharp-dotnet", .pack = packUrl("csharp-dotnet"), .tags = &.{ "csharp", "c#", "dotnet", ".net framework" }, .seeds = &.{ "https://learn.microsoft.com/en-us/dotnet/csharp/", "https://learn.microsoft.com/en-us/dotnet/fundamentals/" } },
    .{ .name = "gradle", .tags = &.{ "gradle", "build.gradle", "gradle wrapper" }, .seeds = &.{ "https://docs.gradle.org/current/userguide/userguide.html", "https://docs.gradle.org/current/dsl/index.html", "https://docs.gradle.org/current/userguide/getting_started_eng.html" } },
    .{ .name = "maven", .tags = &.{ "maven", "pom.xml", "mvn" }, .seeds = &.{ "https://maven.apache.org/guides/index.html", "https://maven.apache.org/guides/getting-started/index.html" }, .kind = .index },

    // — functional & lisp family —
    .{ .name = "haskell", .pack = packUrl("haskell"), .tags = &.{ "haskell", "ghc", "hackage", "cabal" }, .seeds = &.{ "https://www.haskell.org/documentation/", "https://hackage.haskell.org/package/base", "https://downloads.haskell.org/ghc/latest/docs/users_guide/" } },
    .{ .name = "ocaml", .pack = packUrl("ocaml"), .tags = &.{ "ocaml", "opam", "dune build" }, .seeds = &.{ "https://ocaml.org/docs", "https://ocaml.org/manual/" } },
    .{ .name = "elixir", .pack = packUrl("elixir"), .tags = &.{ "elixir", "hexdocs", "iex" }, .seeds = &.{ "https://hexdocs.pm/elixir/Kernel.html", "https://hexdocs.pm/elixir/introduction.html" } },
    .{ .name = "erlang", .pack = packUrl("erlang"), .tags = &.{ "erlang", "erlang otp", "gen_server", "beam vm" }, .seeds = &.{ "https://www.erlang.org/doc/readme.html", "https://www.erlang.org/doc/system/readme.html", "https://www.erlang.org/doc/apps/stdlib/api-reference.html" } },
    .{ .name = "racket", .pack = packUrl("racket"), .tags = &.{ "racket", "scheme language", "drracket" }, .seeds = &.{ "https://docs.racket-lang.org/", "https://docs.racket-lang.org/reference/", "https://docs.racket-lang.org/guide/" } },
    .{ .name = "common-lisp", .pack = packUrl("common-lisp"), .tags = &.{ "common lisp", "hyperspec", "clos", "sbcl" }, .seeds = &.{ "http://www.lispworks.com/documentation/HyperSpec/Front/index.htm", "http://www.lispworks.com/documentation/HyperSpec/Front/Contents.htm" }, .kind = .spec },
    .{ .name = "common-lisp-cookbook", .pack = packUrl("common-lisp"), .tags = &.{ "lisp", "quicklisp", "asdf system definition" }, .seeds = &.{ "https://lispcookbook.github.io/cl-cookbook/", "https://cliki.net/" }, .kind = .cookbook, .trust = 0.7 },

    // — web frontend —
    .{ .name = "typescript-docs", .pack = packUrl("typescript-docs"), .tags = &.{ "typescript", "tsconfig", "tsc", "typescript type annotations", "typescript type system" }, .seeds = &.{ "https://www.typescriptlang.org/docs/handbook/intro.html", "https://www.typescriptlang.org/docs/" } },
    .{ .name = "react-docs", .pack = packUrl("react-docs"), .tags = &.{ "react", "jsx", "react hooks", "usestate", "useeffect" }, .seeds = &.{ "https://react.dev/reference/react", "https://react.dev/learn" } },
    .{ .name = "vue-docs", .pack = packUrl("vue-docs"), .tags = &.{ "vue", "vuejs", "vue 3", "composition api", "single file component" }, .seeds = &.{ "https://vuejs.org/guide/introduction.html", "https://vuejs.org/api/" } },
    .{ .name = "svelte-docs", .pack = packUrl("svelte-docs"), .tags = &.{ "svelte", "sveltekit", "svelte component", "svelte store" }, .seeds = &.{ "https://svelte.dev/docs/svelte/overview", "https://svelte.dev/docs" } },
    .{ .name = "webassembly-docs", .pack = packUrl("webassembly-docs"), .tags = &.{ "webassembly", "wasm", "wasm module", "linear memory" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/WebAssembly", "https://webassembly.github.io/spec/core/" } },
    .{ .name = "web-accessibility", .pack = packUrl("web-accessibility"), .tags = &.{ "accessibility", "a11y", "aria", "wcag", "screen reader" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/Accessibility", "https://www.w3.org/WAI/standards-guidelines/wcag/", "https://www.w3.org/WAI/ARIA/apg/" } },

    // — web backend & api surface —
    .{ .name = "django", .pack = packUrl("web-frameworks"), .tags = &.{ "django", "django orm", "django rest", "django model" }, .seeds = &.{ "https://docs.djangoproject.com/en/stable/", "https://docs.djangoproject.com/en/stable/ref/" } },
    .{ .name = "flask", .pack = packUrl("web-frameworks"), .tags = &.{ "flask", "flask app", "werkzeug", "jinja2" }, .seeds = &.{ "https://flask.palletsprojects.com/en/stable/", "https://flask.palletsprojects.com/en/stable/api/" } },
    .{ .name = "fastapi", .tags = &.{ "fastapi", "pydantic", "starlette", "uvicorn" }, .seeds = &.{ "https://fastapi.tiangolo.com/", "https://fastapi.tiangolo.com/tutorial/" } },
    .{ .name = "express", .pack = packUrl("web-frameworks"), .tags = &.{ "expressjs", "express.js", "express js", "express middleware", "express route", "express server" }, .seeds = &.{ "https://expressjs.com/en/5x/api.html", "https://expressjs.com/en/guide/routing.html" } },
    .{ .name = "deno", .tags = &.{ "deno", "deno runtime", "deno deploy" }, .seeds = &.{ "https://docs.deno.com/runtime/", "https://docs.deno.com/api/deno/" } },
    .{ .name = "graphql", .pack = packUrl("graphql"), .tags = &.{ "graphql", "graphql schema", "graphql query", "graphql mutation", "graphql subscription" }, .seeds = &.{ "https://graphql.org/learn/", "https://spec.graphql.org/October2021/" }, .kind = .tutorial },
    .{ .name = "grpc", .pack = packUrl("grpc"), .tags = &.{"grpc"}, .seeds = &.{ "https://grpc.io/docs/", "https://grpc.io/docs/what-is-grpc/introduction/" } },
    .{ .name = "openapi", .tags = &.{ "openapi", "swagger", "openapi spec", "api specification" }, .seeds = &.{ "https://spec.openapis.org/oas/latest.html", "https://swagger.io/specification/" }, .kind = .spec },
    .{ .name = "rest-api-design", .pack = packUrl("rest-api-design"), .tags = &.{ "api design", "restful", "http api", "api guideline" }, .seeds = &.{ "https://en.wikipedia.org/wiki/REST", "https://raw.githubusercontent.com/microsoft/api-guidelines/vNext/azure/Guidelines.md" }, .trust = 0.8 },
    .{ .name = "software-testing", .pack = packUrl("testing"), .tags = &.{ "software testing", "unit testing methodology", "integration testing strategy", "test automation", "tdd" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Software_testing", "https://martinfowler.com/testing/" }, .trust = 0.8 },

    // — data & machine learning —
    .{ .name = "numpy", .tags = &.{ "numpy", "ndarray", "array programming", "numerical python" }, .seeds = &.{ "https://numpy.org/doc/stable/", "https://numpy.org/doc/stable/reference/index.html", "https://numpy.org/doc/stable/user/index.html" } },
    .{ .name = "pandas", .tags = &.{ "pandas", "dataframe", "pandas data analysis", "data wrangling" }, .seeds = &.{ "https://pandas.pydata.org/docs/", "https://pandas.pydata.org/docs/user_guide/index.html", "https://pandas.pydata.org/docs/reference/index.html" } },
    .{ .name = "scikit-learn", .tags = &.{ "scikit-learn", "sklearn", "scikit-learn model", "sklearn model training" }, .seeds = &.{ "https://scikit-learn.org/stable/", "https://scikit-learn.org/stable/user_guide.html", "https://scikit-learn.org/stable/api/index.html" } },
    .{ .name = "pytorch", .tags = &.{ "pytorch", "torch", "pytorch deep learning", "pytorch neural network", "pytorch tensor" }, .seeds = &.{ "https://docs.pytorch.org/docs/main/index.html", "https://docs.pytorch.org/tutorials/" } },
    .{ .name = "matplotlib", .tags = &.{ "matplotlib", "pyplot", "matplotlib pyplot plotting", "matplotlib figure", "matplotlib chart" }, .seeds = &.{ "https://matplotlib.org/stable/", "https://matplotlib.org/stable/api/index.html", "https://matplotlib.org/stable/users/index.html" } },
    .{ .name = "r-language", .pack = packUrl("r-language"), .tags = &.{ "r language", "rstats", "cran", "statistical computing" }, .seeds = &.{ "https://cran.r-project.org/manuals.html", "https://cran.r-project.org/doc/manuals/r-release/R-intro.html", "https://cran.r-project.org/doc/manuals/r-release/R-lang.html" } },
    .{ .name = "julia", .pack = packUrl("julia"), .tags = &.{ "julia language", "julialang" }, .seeds = &.{ "https://docs.julialang.org/en/v1/", "https://docs.julialang.org/en/v1/manual/getting-started/" } },
    .{ .name = "statistics-fundamentals", .pack = packUrl("statistics-fundamentals"), .tags = &.{ "statistics fundamentals", "probability", "statistical inference", "hypothesis testing", "probability distribution" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Statistics", "https://en.wikipedia.org/wiki/Probability" }, .trust = 0.8 },
    .{ .name = "machine-learning", .tags = &.{ "machine learning", "neural network", "llm", "large language model", "transformer model", "gradient descent", "word embedding", "retrieval-augmented" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Machine_learning", "https://en.wikipedia.org/wiki/Large_language_model", "https://en.wikipedia.org/wiki/Retrieval-augmented_generation" }, .trust = 0.8, .pack = packUrl("machine-learning") },

    // — databases —
    .{ .name = "postgresql", .pack = packUrl("databases"), .tags = &.{ "postgresql", "postgres", "psql" }, .seeds = &.{ "https://www.postgresql.org/docs/current/", "https://www.postgresql.org/docs/current/sql-commands.html" } },
    .{ .name = "mysql", .pack = packUrl("databases"), .tags = &.{ "mysql", "innodb", "mysql server" }, .seeds = &.{ "https://dev.mysql.com/doc/refman/8.4/en/", "https://dev.mysql.com/doc/" } },
    .{ .name = "redis", .tags = &.{ "redis", "redis commands", "redis cache" }, .seeds = &.{ "https://redis.io/docs/latest/", "https://redis.io/docs/latest/commands/" } },
    .{ .name = "mongodb", .pack = packUrl("databases"), .tags = &.{ "mongodb", "mongod", "mongosh", "aggregation pipeline" }, .seeds = &.{"https://www.mongodb.com/docs/manual/"} },
    .{ .name = "sql-theory", .pack = packUrl("databases"), .tags = &.{ "relational model", "database normalization", "relational database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SQL", "https://en.wikipedia.org/wiki/Relational_model", "https://en.wikipedia.org/wiki/Database_normalization" }, .trust = 0.8 },

    // — infra & devops —
    .{ .name = "docker", .pack = packUrl("docker-containers"), .tags = &.{ "docker", "dockerfile", "docker compose", "docker container" }, .seeds = &.{ "https://docs.docker.com/", "https://docs.docker.com/reference/", "https://docs.docker.com/engine/" }, .kind = .index },
    .{ .name = "kubernetes", .pack = packUrl("kubernetes"), .tags = &.{ "kubernetes", "k8s", "kubectl" }, .seeds = &.{ "https://kubernetes.io/docs/home/", "https://kubernetes.io/docs/concepts/", "https://kubernetes.io/docs/reference/" } },
    .{ .name = "terraform", .pack = packUrl("terraform"), .tags = &.{ "terraform", "hcl", "infrastructure as code", "terraform provider" }, .seeds = &.{ "https://developer.hashicorp.com/terraform/docs", "https://developer.hashicorp.com/terraform/language", "https://developer.hashicorp.com/terraform/cli" } },
    .{ .name = "ansible", .pack = packUrl("ansible"), .tags = &.{ "ansible", "ansible playbook", "ansible galaxy" }, .seeds = &.{ "https://docs.ansible.com/ansible/latest/index.html", "https://docs.ansible.com/" } },
    .{ .name = "nginx", .pack = packUrl("nginx"), .tags = &.{ "nginx", "nginx reverse proxy", "nginx conf" }, .seeds = &.{ "https://nginx.org/en/docs/", "https://nginx.org/en/docs/http/ngx_http_core_module.html" } },
    .{ .name = "systemd", .pack = packUrl("sysadmin-ops"), .tags = &.{ "systemd", "systemctl", "journalctl", "unit file" }, .seeds = &.{ "https://www.freedesktop.org/software/systemd/man/latest/", "https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html" } },
    .{ .name = "github-actions", .pack = packUrl("github-actions"), .tags = &.{ "github actions", "github workflow", "actions runner" }, .seeds = &.{ "https://docs.github.com/en/actions", "https://docs.github.com/en/actions/reference" } },

    // — os & networking —
    .{ .name = "tcp-ip", .pack = packUrl("networking"), .tags = &.{ "tcp", "transmission control protocol", "internet protocol suite", "networking stack", "three-way handshake" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc9293.html", "https://en.wikipedia.org/wiki/Internet_protocol_suite" }, .kind = .spec },
    .{ .name = "dns", .pack = packUrl("networking"), .tags = &.{ "dns", "domain name system", "dns name resolution", "nameserver", "dns record" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc1035.html", "https://en.wikipedia.org/wiki/Domain_Name_System" }, .kind = .spec },
    .{ .name = "tls", .pack = packUrl("security"), .tags = &.{ "tls", "ssl", "transport layer security", "tls handshake", "https protocol" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc8446.html", "https://en.wikipedia.org/wiki/Transport_Layer_Security" }, .kind = .spec },
    .{ .name = "ssh", .pack = packUrl("sysadmin-ops"), .tags = &.{ "ssh", "openssh", "secure shell", "ssh key", "remote login" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc4251.html", "https://man.openbsd.org/ssh.1" } },
    .{ .name = "websockets", .pack = packUrl("networking"), .tags = &.{ "websocket", "web socket", "websocket protocol", "socket upgrade" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc6455.html", "https://en.wikipedia.org/wiki/WebSocket" }, .kind = .spec },
    .{ .name = "email-protocols", .pack = packUrl("networking"), .tags = &.{ "smtp", "imap", "email protocol", "mail server", "email delivery" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc5321.html", "https://www.rfc-editor.org/rfc/rfc9051.html" }, .kind = .spec },
    .{ .name = "mqtt", .pack = packUrl("iot-protocols"), .tags = &.{ "mqtt", "iot messaging", "mqtt publish subscribe", "mqtt broker" }, .seeds = &.{ "https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html", "https://mqtt.org/" }, .kind = .spec },
    .{ .name = "operating-systems", .pack = packUrl("operating-systems"), .tags = &.{ "operating system", "os kernel", "virtual memory", "process scheduling", "os theory" }, .seeds = &.{ "https://pages.cs.wisc.edu/~remzi/OSTEP/", "https://en.wikipedia.org/wiki/Operating_system", "https://en.wikipedia.org/wiki/Kernel_(operating_system)" }, .trust = 0.8 },

    // — cs theory —
    .{ .name = "compilers-and-parsing", .pack = packUrl("compilers-and-parsing"), .tags = &.{ "compiler construction", "parser generator", "syntax analysis", "lexer", "lexical analysis", "abstract syntax tree" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Compiler", "https://en.wikipedia.org/wiki/Parsing", "https://en.wikipedia.org/wiki/Lexical_analysis" }, .trust = 0.8 },
    .{ .name = "crafting-interpreters", .pack = packUrl("compilers-and-parsing"), .tags = &.{ "bytecode interpreter", "crafting interpreters", "bytecode", "language implementation" }, .seeds = &.{ "https://craftinginterpreters.com/contents.html", "https://craftinginterpreters.com/" }, .kind = .tutorial, .trust = 0.7 },
    .{ .name = "automata-formal-languages", .pack = packUrl("automata-formal-languages"), .tags = &.{ "automata", "automaton", "finite state machine", "formal language", "context-free grammar", "turing machine" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Automata_theory", "https://en.wikipedia.org/wiki/Formal_language", "https://en.wikipedia.org/wiki/Finite-state_machine" }, .trust = 0.8 },
    .{ .name = "distributed-systems", .pack = packUrl("distributed-systems"), .tags = &.{ "distributed system", "distributed computing", "cap theorem", "consistency model", "eventual consistency" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Distributed_computing", "https://en.wikipedia.org/wiki/CAP_theorem", "https://en.wikipedia.org/wiki/Consistency_model" }, .trust = 0.8 },
    .{ .name = "consensus-algorithms", .pack = packUrl("consensus-algorithms"), .tags = &.{ "consensus algorithm", "consensus protocol", "raft", "paxos", "leader election" }, .seeds = &.{ "https://raft.github.io/", "https://en.wikipedia.org/wiki/Consensus_(computer_science)", "https://en.wikipedia.org/wiki/Paxos_(computer_science)" }, .trust = 0.8 },
    .{ .name = "concurrency", .pack = packUrl("concurrency"), .tags = &.{ "concurrency", "concurrency control", "mutex", "memory ordering", "lock-free", "race condition" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Concurrency_(computer_science)", "https://en.wikipedia.org/wiki/Memory_ordering", "https://preshing.com/archives/" }, .trust = 0.8 },
    .{ .name = "complexity-theory", .pack = packUrl("complexity-theory"), .tags = &.{ "complexity theory", "computational complexity", "np-complete", "np-hard", "time complexity" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Computational_complexity_theory", "https://en.wikipedia.org/wiki/NP-completeness", "https://en.wikipedia.org/wiki/P_versus_NP_problem" }, .trust = 0.8 },

    // — formats & encodings —
    .{ .name = "json", .pack = packUrl("data-formats"), .tags = &.{ "json", "rfc 8259", "json parser", "json serialization" }, .seeds = &.{ "https://www.json.org/json-en.html", "https://www.rfc-editor.org/rfc/rfc8259" }, .kind = .spec },
    .{ .name = "xml", .pack = packUrl("data-formats"), .tags = &.{ "xml", "extensible markup language", "xml namespace", "dtd" }, .seeds = &.{ "https://www.w3.org/TR/xml/", "https://www.w3.org/XML/" }, .kind = .spec },
    .{ .name = "yaml", .pack = packUrl("data-formats"), .tags = &.{ "yaml", "yml", "yaml spec" }, .seeds = &.{"https://yaml.org/spec/1.2.2/"}, .kind = .spec },
    .{ .name = "toml", .pack = packUrl("data-formats"), .tags = &.{ "toml", "toml config", "config file format" }, .seeds = &.{ "https://toml.io/en/v1.0.0", "https://toml.io/en/" }, .kind = .spec },
    .{ .name = "unicode-utf8", .pack = packUrl("encodings-serialization"), .tags = &.{ "unicode", "utf-8", "utf8", "character encoding", "codepoint", "byte order mark" }, .seeds = &.{ "https://www.unicode.org/faq/utf_bom.html", "https://en.wikipedia.org/wiki/UTF-8" }, .trust = 0.9 },
    .{ .name = "protobuf", .pack = packUrl("encodings-serialization"), .tags = &.{ "protobuf", "protocol buffers", "proto3", "proto file" }, .seeds = &.{ "https://protobuf.dev/", "https://protobuf.dev/programming-guides/proto3/" } },
    .{ .name = "markdown", .pack = packUrl("data-formats"), .tags = &.{ "markdown", "commonmark", "md syntax" }, .seeds = &.{ "https://spec.commonmark.org/0.31.2/", "https://daringfireball.net/projects/markdown/syntax" }, .kind = .spec },
    .{ .name = "base64-mime", .pack = packUrl("data-formats"), .tags = &.{ "base64", "base32", "mime type", "content-transfer-encoding", "data encoding" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc4648", "https://www.rfc-editor.org/rfc/rfc2045" }, .kind = .spec },

    // — security & crypto —
    .{ .name = "crypto-fundamentals", .pack = packUrl("crypto"), .tags = &.{ "cryptography", "public-key", "aes", "sha-256", "hmac", "encryption" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Public-key_cryptography", "https://en.wikipedia.org/wiki/Advanced_Encryption_Standard", "https://en.wikipedia.org/wiki/SHA-2" }, .trust = 0.8 },
    .{ .name = "libsodium", .tags = &.{ "libsodium", "sodium library", "nacl", "secretbox" }, .seeds = &.{ "https://doc.libsodium.org/", "https://doc.libsodium.org/password_hashing" } },
    .{ .name = "jwt", .pack = packUrl("security"), .tags = &.{ "jwt", "json web token", "jwt bearer token" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc7519", "https://jwt.io/introduction" }, .kind = .spec },
    .{ .name = "oauth2", .pack = packUrl("security"), .tags = &.{ "oauth", "oauth2", "oauth 2.0", "authorization code", "oauth access token" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc6749", "https://oauth.net/2/" }, .kind = .spec },
    .{ .name = "cwe-cve", .pack = packUrl("security"), .tags = &.{ "cwe", "cve", "cve vulnerability database", "weakness enumeration" }, .seeds = &.{ "https://cwe.mitre.org/", "https://cwe.mitre.org/data/index.html", "https://en.wikipedia.org/wiki/Common_Vulnerabilities_and_Exposures" }, .kind = .index },
    .{ .name = "argon2-password-hashing", .pack = packUrl("security"), .tags = &.{ "argon2", "password storage", "key derivation" }, .seeds = &.{ "https://www.rfc-editor.org/rfc/rfc9106", "https://en.wikipedia.org/wiki/Argon2" }, .kind = .spec },

    // — mobile & embedded —
    .{ .name = "swift-language", .pack = packUrl("swift-language"), .tags = &.{ "swift language", "swiftui", "ios" }, .seeds = &.{ "https://www.swift.org/documentation/", "https://www.swift.org/getting-started/", "https://www.swift.org/documentation/api-design-guidelines/" }, .kind = .index },
    .{ .name = "flutter", .pack = packUrl("dart"), .tags = &.{ "flutter", "flutter widget", "flutter app" }, .seeds = &.{ "https://docs.flutter.dev/", "https://docs.flutter.dev/get-started/install" }, .kind = .index },
    .{ .name = "dart", .pack = packUrl("dart"), .tags = &.{ "dart language", "dart sdk", "dartlang" }, .seeds = &.{ "https://dart.dev/guides", "https://dart.dev/language" } },
    .{ .name = "android", .tags = &.{ "android", "android studio", "android sdk", "jetpack compose" }, .seeds = &.{ "https://developer.android.com/docs", "https://developer.android.com/guide" }, .kind = .index },
    .{ .name = "arduino", .pack = packUrl("arduino"), .tags = &.{ "arduino", "arduino sketch", "arduino uno", "arduino ide" }, .seeds = &.{ "https://docs.arduino.cc/", "https://docs.arduino.cc/language-reference/" }, .kind = .index },
    .{ .name = "esp32", .pack = packUrl("esp32"), .tags = &.{ "esp32", "esp-idf", "espressif" }, .seeds = &.{ "https://docs.espressif.com/projects/esp-idf/en/latest/esp32/", "https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/index.html" } },
    .{ .name = "raspberry-pi", .pack = packUrl("raspberry-pi"), .tags = &.{ "raspberry pi", "raspberry pi os", "raspbian", "pi pico" }, .seeds = &.{ "https://github.com/raspberrypi/documentation", "https://en.wikipedia.org/wiki/Raspberry_Pi" }, .kind = .index, .trust = 0.8 },
    .{ .name = "freertos", .pack = packUrl("freertos"), .tags = &.{ "freertos", "rtos", "real-time operating system" }, .seeds = &.{ "https://github.com/FreeRTOS/FreeRTOS-Kernel", "https://en.wikipedia.org/wiki/FreeRTOS" }, .trust = 0.8 },

    // — gamedev & graphics —
    .{ .name = "opengl", .pack = packUrl("graphics"), .tags = &.{ "opengl", "glfw", "glew", "gl4" }, .seeds = &.{ "https://registry.khronos.org/OpenGL-Refpages/gl4/html/indexflat.php", "https://docs.gl/" } },
    .{ .name = "webgl", .pack = packUrl("graphics"), .tags = &.{ "webgl", "webgl2", "webgl context" }, .seeds = &.{ "https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API", "https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Tutorial/Getting_started_with_WebGL" } },
    .{ .name = "vulkan", .pack = packUrl("graphics"), .tags = &.{ "vulkan", "vulkan sdk", "vkcreateinstance" }, .seeds = &.{ "https://docs.vulkan.org/spec/latest/index.html", "https://docs.vulkan.org/guide/latest/index.html" }, .kind = .spec },
    .{ .name = "godot", .pack = packUrl("game-dev"), .tags = &.{ "godot", "gdscript", "godot engine" }, .seeds = &.{ "https://docs.godotengine.org/en/stable/", "https://docs.godotengine.org/en/stable/classes/index.html" } },
    .{ .name = "sdl", .pack = packUrl("game-dev"), .tags = &.{ "sdl2", "sdl3", "libsdl" }, .seeds = &.{ "https://wiki.libsdl.org/SDL3/FrontPage", "https://wiki.libsdl.org/SDL3/SDL_Init" } },
    .{ .name = "game-programming-patterns", .pack = packUrl("game-dev"), .tags = &.{ "game programming patterns", "game loop", "game design pattern", "entity component" }, .seeds = &.{"https://gameprogrammingpatterns.com/contents.html"}, .kind = .cookbook, .trust = 0.7 },
    .{ .name = "shaders", .pack = packUrl("graphics"), .tags = &.{ "shader", "glsl", "fragment shader", "vertex shader" }, .seeds = &.{ "https://thebookofshaders.com/", "https://thebookofshaders.com/01/" }, .kind = .tutorial, .trust = 0.7 },

    // — software-engineering practice —
    .{ .name = "semantic-versioning", .pack = packUrl("swe-practice"), .tags = &.{ "semver", "semantic versioning", "version numbering", "software versioning" }, .seeds = &.{ "https://semver.org/", "https://en.wikipedia.org/wiki/Software_versioning" }, .kind = .spec },
    .{ .name = "software-licenses", .pack = packUrl("swe-practice"), .tags = &.{ "software license", "open source license", "spdx", "mit license", "gpl" }, .seeds = &.{ "https://spdx.org/licenses/", "https://choosealicense.com/", "https://opensource.org/licenses" }, .kind = .index },
    .{ .name = "documentation-practice", .pack = packUrl("swe-practice"), .tags = &.{ "documentation best practices", "technical writing", "diataxis", "how-to guide", "docs structure" }, .seeds = &.{ "https://diataxis.fr/", "https://documentation.divio.com/" } },
    .{ .name = "twelve-factor-app", .pack = packUrl("swe-practice"), .tags = &.{ "twelve-factor", "12factor", "twelve factor app", "cloud native" }, .seeds = &.{ "https://12factor.net/", "https://en.wikipedia.org/wiki/Twelve-Factor_App_methodology" } },

    // — math & numerics —
    .{ .name = "linear-algebra", .pack = packUrl("linear-algebra"), .tags = &.{ "linear algebra", "matrix algebra", "matrices", "eigenvalue", "vector space", "dot product" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Linear_algebra", "https://en.wikipedia.org/wiki/Matrix_(mathematics)", "https://immersivemath.com/ila/index.html" }, .trust = 0.8 },
    .{ .name = "calculus", .pack = packUrl("calculus"), .tags = &.{ "calculus", "differential calculus", "integral calculus", "differentiation", "antiderivative" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Calculus", "https://en.wikipedia.org/wiki/Derivative", "https://en.wikipedia.org/wiki/Integral" }, .trust = 0.8 },
    .{ .name = "discrete-mathematics", .pack = packUrl("discrete-mathematics"), .tags = &.{ "discrete math", "discrete mathematics", "combinatorics", "graph theory", "set theory", "permutation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Discrete_mathematics", "https://en.wikipedia.org/wiki/Graph_theory", "https://en.wikipedia.org/wiki/Combinatorics" }, .trust = 0.8 },
    .{ .name = "number-theory", .pack = packUrl("number-theory"), .tags = &.{ "number theory", "modular arithmetic", "prime number", "gcd" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Number_theory", "https://en.wikipedia.org/wiki/Modular_arithmetic", "https://en.wikipedia.org/wiki/Prime_number" }, .trust = 0.8 },
    .{ .name = "numerical-methods", .pack = packUrl("numerical-methods"), .tags = &.{ "numerical analysis", "numerical method", "root finding", "polynomial interpolation", "numerical integration" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Numerical_analysis", "https://en.wikipedia.org/wiki/Newton%27s_method" }, .trust = 0.8 },
    .{ .name = "floating-point", .pack = packUrl("floating-point"), .tags = &.{ "floating point", "ieee 754", "rounding error", "double precision", "machine epsilon" }, .seeds = &.{ "https://en.wikipedia.org/wiki/IEEE_754", "https://floating-point-gui.de/", "https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html" }, .trust = 0.8 },
    // — the nl-rag mega-pack block: paradigms, problem solving, physical computing (embedded/
    // IoT/electronics/control/DSP/FPGA/PLC/robotics), mathematics, systems theory, patterns, and
    // practice — every entry carries a pre-normalized pack; seeds stay canonical for freshness —
    .{ .name = "paradigms", .pack = packUrl("paradigms"), .tags = &.{ "programming paradigm", "object-oriented", "functional programming", "imperative programming", "declarative programming", "metaprogramming" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Programming_paradigm", "https://en.wikipedia.org/wiki/Functional_programming" }, .trust = 0.8 },
    .{ .name = "problem-solving", .pack = packUrl("problem-solving"), .tags = &.{ "problem solving", "heuristic", "backtracking", "computational thinking", "divide and conquer", "constraint satisfaction" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Problem_solving", "https://en.wikipedia.org/wiki/How_to_Solve_It" }, .trust = 0.8 },
    .{ .name = "embedded-systems", .pack = packUrl("embedded-systems"), .tags = &.{ "embedded system", "embedded device", "microcontroller", "firmware", "bare metal", "bootloader" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Embedded_system", "https://en.wikipedia.org/wiki/Microcontroller" }, .trust = 0.8 },
    .{ .name = "iot-protocols", .pack = packUrl("iot-protocols"), .tags = &.{ "iot", "internet of things", "zigbee", "coap", "lora", "smart home", "ble" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Internet_of_things", "https://en.wikipedia.org/wiki/MQTT" }, .trust = 0.8 },
    .{ .name = "hardware-interfaces", .pack = packUrl("hardware-interfaces"), .tags = &.{ "i2c", "spi", "uart", "gpio", "pwm", "can bus", "modbus", "jtag" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Serial_Peripheral_Interface", "https://en.wikipedia.org/wiki/CAN_bus" }, .trust = 0.8 },
    .{ .name = "electronics", .pack = packUrl("electronics"), .tags = &.{ "electronics", "resistor", "capacitor", "transistor", "voltage", "logic gate", "schematic" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ohm's_law", "https://en.wikipedia.org/wiki/Transistor" }, .trust = 0.8 },
    .{ .name = "control-systems", .pack = packUrl("control-systems"), .tags = &.{ "pid controller", "control loop", "control theory", "kalman filter", "servo", "setpoint" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Control_theory", "https://en.wikipedia.org/wiki/PID_controller" }, .trust = 0.8 },
    .{ .name = "dsp", .pack = packUrl("dsp"), .tags = &.{ "dsp", "signal processing", "fft", "fourier", "digital filter", "sampling rate" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Digital_signal_processing", "https://en.wikipedia.org/wiki/Fast_Fourier_transform" }, .trust = 0.8 },
    .{ .name = "fpga-hdl", .pack = packUrl("fpga-hdl"), .tags = &.{ "fpga", "verilog", "vhdl", "hardware description" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Field-programmable_gate_array", "https://en.wikipedia.org/wiki/Verilog" }, .trust = 0.8 },
    .{ .name = "plc-scada", .pack = packUrl("plc-scada"), .tags = &.{ "plc", "scada", "ladder logic", "industrial control", "iec 61131" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Programmable_logic_controller", "https://en.wikipedia.org/wiki/SCADA" }, .trust = 0.8 },
    .{ .name = "robotics", .pack = packUrl("robotics"), .tags = &.{ "robotics", "kinematics", "path planning", "ros2", "odometry" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Robotics", "https://en.wikipedia.org/wiki/Robot_Operating_System" }, .trust = 0.8 },
    .{ .name = "real-time-systems", .pack = packUrl("real-time-systems"), .tags = &.{ "rtos", "hard real-time", "real-time scheduling", "preemption", "interrupt latency" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Real-time_computing", "https://en.wikipedia.org/wiki/Real-time_operating_system" }, .trust = 0.8 },
    .{ .name = "computer-architecture", .pack = packUrl("computer-architecture"), .tags = &.{ "computer architecture", "cpu cache", "instruction pipeline", "branch prediction", "virtual memory", "cache line" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Computer_architecture", "https://en.wikipedia.org/wiki/CPU_cache" }, .trust = 0.8 },
    .{ .name = "logic-foundations", .pack = packUrl("logic-foundations"), .tags = &.{ "propositional logic", "first-order logic", "boolean algebra", "truth table", "formal logic" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Propositional_calculus", "https://en.wikipedia.org/wiki/Boolean_algebra" }, .trust = 0.8 },
    .{ .name = "lambda-type-theory", .pack = packUrl("lambda-type-theory"), .tags = &.{ "lambda calculus", "type theory", "type system", "type inference", "algebraic data type" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Lambda_calculus", "https://en.wikipedia.org/wiki/Type_system" }, .trust = 0.8 },
    .{ .name = "category-theory", .pack = packUrl("category-theory"), .tags = &.{ "category theory", "functor", "monad", "morphism" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Category_theory", "https://en.wikipedia.org/wiki/Functor" }, .trust = 0.8 },
    .{ .name = "information-theory", .pack = packUrl("information-theory"), .tags = &.{ "information theory", "entropy", "error correction", "hamming", "checksum", "crc" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Information_theory", "https://en.wikipedia.org/wiki/Error_detection_and_correction" }, .trust = 0.8 },
    .{ .name = "computational-geometry", .pack = packUrl("computational-geometry"), .tags = &.{ "computational geometry", "convex hull", "voronoi", "triangulation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Computational_geometry", "https://en.wikipedia.org/wiki/Convex_hull" }, .trust = 0.8 },
    .{ .name = "optimization", .pack = packUrl("optimization"), .tags = &.{ "mathematical optimization", "linear programming", "convex optimization", "simplex", "knapsack", "traveling salesman" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Mathematical_optimization", "https://en.wikipedia.org/wiki/Linear_programming" }, .trust = 0.8 },
    .{ .name = "formal-methods", .pack = packUrl("formal-methods"), .tags = &.{ "formal verification", "formal method", "model checking", "tla+", "hoare logic" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Formal_verification", "https://en.wikipedia.org/wiki/Model_checking" }, .trust = 0.8 },
    .{ .name = "performance-engineering", .pack = packUrl("performance-engineering"), .tags = &.{ "performance optimization", "profiling", "benchmark", "memoization", "latency" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Program_optimization", "https://en.wikipedia.org/wiki/Profiling_(computer_programming)" }, .trust = 0.8 },
    .{ .name = "compression", .pack = packUrl("compression"), .tags = &.{ "compression", "huffman", "deflate", "gzip", "zstd", "lz77" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Data_compression", "https://en.wikipedia.org/wiki/Huffman_coding" }, .trust = 0.8 },
    .{ .name = "architecture-patterns", .pack = packUrl("architecture-patterns"), .tags = &.{ "event-driven architecture", "cqrs", "message broker", "publish-subscribe", "microservice architecture", "hexagonal" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Software_architecture", "https://en.wikipedia.org/wiki/Event-driven_architecture" }, .trust = 0.8 },
    .{ .name = "concurrency-patterns", .pack = packUrl("concurrency-patterns"), .tags = &.{ "thread pool", "lock-free", "compare-and-swap", "spinlock", "memory barrier", "atomic operation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Thread_pool", "https://en.wikipedia.org/wiki/Non-blocking_algorithm" }, .trust = 0.8 },
    .{ .name = "code-quality", .pack = packUrl("code-quality"), .tags = &.{ "code smell", "technical debt", "cyclomatic complexity", "clean code", "code quality" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Code_refactoring", "https://en.wikipedia.org/wiki/Code_smell" }, .trust = 0.8 },
    .{ .name = "agile-devops", .pack = packUrl("agile-devops"), .tags = &.{ "agile", "scrum", "kanban", "devops", "continuous delivery" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Agile_software_development", "https://en.wikipedia.org/wiki/DevOps" }, .trust = 0.8 },
    .{ .name = "sre-observability", .pack = packUrl("sre-observability"), .tags = &.{ "observability", "site reliability", "sre", "high availability", "fault tolerance", "chaos engineering" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Site_reliability_engineering", "https://en.wikipedia.org/wiki/High_availability" }, .trust = 0.8 },
    .{ .name = "classic-ai", .pack = packUrl("classic-ai"), .tags = &.{ "artificial intelligence", "expert system", "knowledge representation", "nlp", "computer vision", "speech recognition" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Artificial_intelligence", "https://en.wikipedia.org/wiki/Natural_language_processing" }, .trust = 0.8 },
    .{ .name = "data-engineering", .pack = packUrl("data-engineering"), .tags = &.{ "etl", "data pipeline", "data warehouse", "kafka", "stream processing", "message queue" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Extract,_transform,_load", "https://en.wikipedia.org/wiki/Apache_Kafka" }, .trust = 0.8 },
    .{ .name = "caching", .pack = packUrl("caching"), .tags = &.{ "caching", "cache invalidation", "cdn", "consistent hashing", "memcached" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cache_replacement_policies", "https://en.wikipedia.org/wiki/Content_delivery_network" }, .trust = 0.8 },
    .{ .name = "cloud-computing", .pack = packUrl("cloud-computing"), .tags = &.{ "cloud computing", "serverless", "virtualization", "hypervisor", "iaas", "paas", "saas" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cloud_computing", "https://en.wikipedia.org/wiki/Serverless_computing" }, .trust = 0.8 },
    .{ .name = "graphics", .pack = packUrl("graphics"), .tags = &.{ "computer graphics", "ray tracing", "rasterization", "render pipeline", "texture mapping" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Computer_graphics", "https://en.wikipedia.org/wiki/Graphics_pipeline" }, .trust = 0.8 },
    .{ .name = "game-dev", .pack = packUrl("game-dev"), .tags = &.{ "game development", "game engine", "game loop", "collision detection", "entity component" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Video_game_development", "https://en.wikipedia.org/wiki/Game_engine" }, .trust = 0.8 },
    .{ .name = "legacy-languages", .pack = packUrl("legacy-languages"), .tags = &.{ "fortran", "cobol", "smalltalk", "prolog", "apl", "ada language", "pascal language" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Fortran", "https://en.wikipedia.org/wiki/COBOL" }, .trust = 0.8 },
    .{ .name = "arm-riscv", .pack = packUrl("arm-riscv"), .tags = &.{ "arm cortex", "aarch64", "risc-v", "riscv", "arm architecture", "instruction set" }, .seeds = &.{ "https://en.wikipedia.org/wiki/ARM_architecture_family", "https://en.wikipedia.org/wiki/RISC-V" }, .trust = 0.8 },
    .{ .name = "canonical-books", .pack = packUrl("canonical-books"), .tags = &.{ "sicp", "taocp", "programming book", "mythical man-month", "pragmatic programmer" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Structure_and_Interpretation_of_Computer_Programs", "https://en.wikipedia.org/wiki/The_Art_of_Computer_Programming" }, .trust = 0.7 },
    .{ .name = "rosetta-code", .pack = packUrl("rosetta-code"), .tags = &.{ "rosetta code", "cross-language", "polyglot" }, .seeds = &.{ "https://rosettacode.org/wiki/Rosetta_Code", "https://en.wikipedia.org/wiki/Rosetta_Code" }, .trust = 0.7 },
};

/// Case-insensitive word-bounded hit, with trailing-'s' tolerance so "algorithms" reaches tag "algorithm".
/// Word-bounding is load-bearing: "rust" must never fire inside "trust", "ruby" not inside "rubytest".
fn wordHit(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or text.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (!std.ascii.startsWithIgnoreCase(text[i..], needle)) continue;
        if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
        var after = i + needle.len;
        if (after < text.len and (text[after] == 's' or text[after] == 'S')) after += 1; // plural tolerance
        if (after < text.len and std.ascii.isAlphanumeric(text[after])) continue;
        return true;
    }
    return false;
}

const Scored = struct { loc: *const Loc, score: f32 };

/// Rank atlas entries against free text (gap report + goal). Score = word-bounded tag hits × the entry's
/// trust prior. Returns the number of matches written into `out`, best first. Pure and allocation-free —
/// callable from any hot path.
pub fn match(text: []const u8, out: []*const Loc) usize {
    var scored: [ATLAS.len]Scored = undefined;
    var n: usize = 0;
    for (&ATLAS) |*loc| {
        var hits: f32 = 0;
        for (loc.tags) |t| {
            if (wordHit(text, t)) hits += 1;
        }
        if (hits > 0) {
            scored[n] = .{ .loc = loc, .score = hits * loc.trust };
            n += 1;
        }
    }
    // tiny N: insertion sort, stable (earlier atlas entries win ties)
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = scored[i];
        var j = i;
        while (j > 0 and scored[j - 1].score < key.score) : (j -= 1) scored[j] = scored[j - 1];
        scored[j] = key;
    }
    const k = @min(n, out.len);
    for (0..k) |x| out[x] = scored[x].loc;
    return k;
}

/// The "CANONICAL SOURCES" block appended to a research directive: the top matched domains with their seed
/// urls, framed as look-here-FIRST (search stays the fallback and stays first-class for everything else).
/// "" when nothing matches — the caller appends nothing and the directive reads exactly as before.
pub fn sourcesBlock(gpa: std.mem.Allocator, text: []const u8, max_locs: usize) []const u8 {
    var top: [3]*const Loc = undefined;
    const n = match(text, top[0..@min(max_locs, top.len)]);
    if (n == 0) return "";
    var b: std.ArrayListUnmanaged(u8) = .empty;
    defer b.deinit(gpa);
    b.appendSlice(gpa, " CANONICAL SOURCES for this domain (curated — web_fetch/deep_crawl these FIRST; a PACK url serves pre-normalized markdown: fetch the pack INDEX, then fetch any page it lists; use web_search only when they don't answer or the topic is outside them): ") catch {};
    for (0..n) |i| {
        if (i > 0) b.appendSlice(gpa, " | ") catch {};
        b.append(gpa, '[') catch {};
        b.appendSlice(gpa, top[i].name) catch {};
        b.appendSlice(gpa, "] ") catch {};
        if (top[i].pack.len > 0) {
            b.appendSlice(gpa, "PACK ") catch {};
            b.appendSlice(gpa, top[i].pack) catch {};
            b.append(gpa, ' ') catch {};
        }
        for (top[i].seeds, 0..) |s, si| {
            if (si > 0) b.append(gpa, ' ') catch {};
            b.appendSlice(gpa, s) catch {};
        }
    }
    return gpa.dupe(u8, b.items) catch "";
}

test "atlas match: word-bounded domain routing — rust never fires inside trust" {
    var top: [3]*const Loc = undefined;
    const n = match("Build a REST API in Rust with cargo and integration tests", &top);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqualStrings("rust", top[0].name); // 2 tag hits × 1.0 beats http-rest's 1 hit
    // "trust the process, adjust the gain" must not look like Rust
    var t2: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("trust the process, adjust the gain", &t2));
}

test "atlas match: plural tolerance + multi-domain + no-match stays empty" {
    var top: [3]*const Loc = undefined;
    const n = match("implement sorting algorithms in Python", &top);
    try std.testing.expect(n >= 2); // python + algorithms both matched
    var names_buf: [3][]const u8 = undefined;
    for (0..n) |i| names_buf[i] = top[i].name;
    var saw_py = false;
    var saw_algo = false;
    for (names_buf[0..n]) |nm| {
        if (std.mem.eql(u8, nm, "python")) saw_py = true;
        if (std.mem.eql(u8, nm, "algorithms")) saw_algo = true;
    }
    try std.testing.expect(saw_py and saw_algo);
    var t2: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("bake a chocolate cake for the party", &t2));
}

test "sourcesBlock: renders top domains with seeds, empty for unmatched text" {
    const gpa = std.testing.allocator;
    const blk = sourcesBlock(gpa, "PBKDF2 password hashing and session token auth in Python", 3);
    defer if (blk.len > 0) gpa.free(@constCast(blk));
    try std.testing.expect(std.mem.indexOf(u8, blk, "docs.python.org") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk, "cheatsheetseries.owasp.org") != null);
    const none = sourcesBlock(gpa, "narrate a short story about winter", 3);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "pack wiring: covered domains render the PACK url ahead of seeds, uncovered domains stay seed-only" {
    const gpa = std.testing.allocator;
    const blk = sourcesBlock(gpa, "sort a list in Python", 3);
    defer if (blk.len > 0) gpa.free(@constCast(blk));
    try std.testing.expect(std.mem.indexOf(u8, blk, "PACK https://raw.githubusercontent.com/gary23w/nl-rag/main/packs/python/INDEX.md") != null);
    const pack_at = std.mem.indexOf(u8, blk, "PACK ").?;
    const seed_at = std.mem.indexOf(u8, blk, "https://docs.python.org").?;
    try std.testing.expect(pack_at < seed_at); // the pre-normalized mirror is the first thing a scout sees
    // a pack-less domain must render exactly as before — no PACK marker anywhere
    const blk2 = sourcesBlock(gpa, "configure the gradle wrapper for this build", 3);
    defer if (blk2.len > 0) gpa.free(@constCast(blk2));
    try std.testing.expect(std.mem.indexOf(u8, blk2, "gradle") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk2, "PACK https://") == null); // framing mentions PACK; no entry carries one
}

test "mega-pack block: physical-computing routing fires, generic prose stays silent" {
    const gpa = std.testing.allocator;
    // an embedded goal reaches the new domains WITH their packs
    const blk = sourcesBlock(gpa, "tune the PID controller reading the sensor over i2c on the microcontroller", 3);
    defer if (blk.len > 0) gpa.free(@constCast(blk));
    try std.testing.expect(std.mem.indexOf(u8, blk, "control-systems") != null);
    try std.testing.expect(std.mem.indexOf(u8, blk, "packs/control-systems/INDEX.md") != null);
    // tag-safety: common English words neighboring new tags must not route
    var t: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("slam the door and walk back and forth to the robots.txt meeting", &t));
    try std.testing.expectEqual(@as(usize, 0), match("please optimize this function for speed", &t));
}

test "atlas audit: common-word tags de-fanged, dedicated domains own their tags, new domains reachable" {
    // generic dev prose that used to false-fire audited tags ("chart", "statistics", "debugging",
    // bare "julia") must match NOTHING now
    var t0: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("add a chart to the admin dashboard and collect usage statistics", &t0));
    try std.testing.expectEqual(@as(usize, 0), match("Julia, an analyst, is debugging the payment workflow", &t0));
    // explicit gdb prose still reaches gdb, and react rides along — both, not one masking the other
    var t1: [3]*const Loc = undefined;
    const n1 = match("debugging the React app with gdb breakpoints", &t1);
    var saw_gdb = false;
    var saw_react = false;
    for (t1[0..n1]) |l| {
        if (std.mem.eql(u8, l.name, "gdb-debugging")) saw_gdb = true;
        if (std.mem.eql(u8, l.name, "react-docs")) saw_react = true;
    }
    try std.testing.expect(saw_gdb and saw_react);
    // duplicate-domain fix: protobuf prose routes to protobuf only, never co-fires grpc
    var t2: [3]*const Loc = undefined;
    const n2 = match("serialize the record as a protobuf proto3 message", &t2);
    try std.testing.expect(n2 >= 1);
    try std.testing.expectEqualStrings("protobuf", t2[0].name);
    for (t2[0..n2]) |l| try std.testing.expect(!std.mem.eql(u8, l.name, "grpc"));
    // a domain far outside the original base block is reachable
    var t3: [3]*const Loc = undefined;
    const n3 = match("write a Kotlin data class and store rows in PostgreSQL", &t3);
    var saw_kt = false;
    var saw_pg = false;
    for (t3[0..n3]) |l| {
        if (std.mem.eql(u8, l.name, "kotlin")) saw_kt = true;
        if (std.mem.eql(u8, l.name, "postgresql")) saw_pg = true;
    }
    try std.testing.expect(saw_kt and saw_pg);
}
