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
    // — mega-pack wave 3: the highest-traffic nl-rag domains a coding/defense swarm hits —
    // ML/AI frameworks, vector DBs, cloud, web frameworks, devops, OS internals, defensive
    // security, blockchain, and advanced math. Tags come from the nl-rag registry (tag-safety
    // authored), bare-common-word filtered; every entry carries its pack. trust 0.8 so the
    // hand-curated core still wins score ties. —
    .{ .name = "tensorflow", .pack = packUrl("tensorflow"), .tags = &.{ "tensorflow framework", "deep learning framework", "google brain", "dataflow graph", "tpu accelerator" }, .seeds = &.{ "https://en.wikipedia.org/wiki/TensorFlow" }, .trust = 0.8 },
    .{ .name = "keras", .pack = packUrl("keras"), .tags = &.{ "keras api", "neural network library", "high level api", "model training" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Keras" }, .trust = 0.8 },
    .{ .name = "jax-ml", .pack = packUrl("jax-ml"), .tags = &.{ "jax library", "autograd differentiation", "just in time compilation", "numpy vectorization", "accelerator computing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/JAX_(software)" }, .trust = 0.8 },
    .{ .name = "huggingface-transformers", .pack = packUrl("huggingface-transformers"), .tags = &.{ "hugging face", "transformers library", "pretrained model", "language model hub" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Hugging_Face" }, .trust = 0.8 },
    .{ .name = "langchain", .pack = packUrl("langchain"), .tags = &.{ "langchain framework", "llm application", "retrieval augmented generation", "prompt chaining", "ai agent" }, .seeds = &.{ "https://en.wikipedia.org/wiki/LangChain" }, .trust = 0.8 },
    .{ .name = "llamaindex", .pack = packUrl("llamaindex"), .tags = &.{ "llamaindex framework", "data indexing", "retrieval augmented generation", "document retrieval", "knowledge base" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Retrieval-augmented_generation" }, .trust = 0.8 },
    .{ .name = "onnx", .pack = packUrl("onnx"), .tags = &.{ "onnx format", "model interoperability", "inference engine", "neural network exchange" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Open_Neural_Network_Exchange" }, .trust = 0.8 },
    .{ .name = "opencv", .pack = packUrl("opencv"), .tags = &.{ "opencv library", "computer vision", "image processing", "feature detection", "optical flow" }, .seeds = &.{ "https://en.wikipedia.org/wiki/OpenCV" }, .trust = 0.8 },
    .{ .name = "spacy-nlp", .pack = packUrl("spacy-nlp"), .tags = &.{ "spacy library", "natural language processing", "named entity recognition", "dependency parsing", "part of speech" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SpaCy" }, .trust = 0.8 },
    .{ .name = "cuda-programming", .pack = packUrl("cuda-programming"), .tags = &.{ "cuda programming", "gpu computing", "parallel kernel", "nvidia accelerator", "gpgpu" }, .seeds = &.{ "https://en.wikipedia.org/wiki/CUDA" }, .trust = 0.8 },
    .{ .name = "rag-systems", .pack = packUrl("rag-systems"), .tags = &.{ "rag pipeline", "retrieval augmented generation", "vector retrieval", "semantic search", "grounded generation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Retrieval-augmented_generation" }, .trust = 0.8 },
    .{ .name = "llm-fine-tuning", .pack = packUrl("llm-fine-tuning"), .tags = &.{ "fine tuning llm", "parameter efficient", "instruction tuning", "domain adaptation", "supervised finetuning" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Fine-tuning_(deep_learning)" }, .trust = 0.8 },
    .{ .name = "model-quantization", .pack = packUrl("model-quantization"), .tags = &.{ "model quantization", "low precision", "integer inference", "post training quantization", "weight compression" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Quantization_(signal_processing)" }, .trust = 0.8 },
    .{ .name = "vector-search", .pack = packUrl("vector-search"), .tags = &.{ "vector search", "nearest neighbor", "approximate search", "similarity search", "vector database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Nearest_neighbor_search" }, .trust = 0.8 },
    .{ .name = "model-embeddings", .pack = packUrl("model-embeddings"), .tags = &.{ "vector embeddings", "word embedding", "sentence embedding", "representation learning", "latent vector" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Word_embedding" }, .trust = 0.8 },
    .{ .name = "graph-neural-networks", .pack = packUrl("graph-neural-networks"), .tags = &.{ "graph neural network", "message passing", "node embedding", "graph representation", "relational learning" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Graph_neural_network" }, .trust = 0.8 },
    .{ .name = "elasticsearch", .pack = packUrl("elasticsearch"), .tags = &.{ "elasticsearch", "apache lucene", "full-text search engine", "inverted index" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Elasticsearch", "https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html" }, .trust = 0.8 },
    .{ .name = "clickhouse", .pack = packUrl("clickhouse"), .tags = &.{ "clickhouse", "columnar olap", "mergetree engine", "column-oriented dbms" }, .seeds = &.{ "https://en.wikipedia.org/wiki/ClickHouse", "https://clickhouse.com/docs/en/intro" }, .trust = 0.8 },
    .{ .name = "duckdb", .pack = packUrl("duckdb"), .tags = &.{ "duckdb", "embedded analytics", "olap engine", "apache parquet" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DuckDB", "https://duckdb.org/why_duckdb" }, .trust = 0.8 },
    .{ .name = "cassandra-db", .pack = packUrl("cassandra-db"), .tags = &.{ "cassandra", "wide-column store", "apache cassandra", "gossip protocol" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Cassandra", "https://cassandra.apache.org/doc/stable/cassandra/architecture/overview.html" }, .trust = 0.8 },
    .{ .name = "neo4j", .pack = packUrl("neo4j"), .tags = &.{ "neo4j", "cypher query language", "property graph", "graph database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Neo4j", "https://neo4j.com/docs/getting-started/" }, .trust = 0.8 },
    .{ .name = "cockroachdb", .pack = packUrl("cockroachdb"), .tags = &.{ "cockroachdb", "distributed sql", "cockroach labs", "distributed database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/CockroachDB", "https://www.cockroachlabs.com/docs/stable/architecture/overview.html" }, .trust = 0.8 },
    .{ .name = "pinecone", .pack = packUrl("pinecone"), .tags = &.{ "pinecone vector db", "managed vector database", "vector similarity search", "locality-sensitive hashing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Vector_database", "https://docs.pinecone.io/guides/get-started/overview" }, .trust = 0.8 },
    .{ .name = "qdrant", .pack = packUrl("qdrant"), .tags = &.{ "qdrant", "vector database", "vector similarity search", "approximate nearest neighbor" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Qdrant", "https://qdrant.tech/documentation/" }, .trust = 0.8 },
    .{ .name = "milvus", .pack = packUrl("milvus"), .tags = &.{ "milvus", "vector database", "similarity search engine", "vector quantization" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Milvus_(vector_database)", "https://github.com/milvus-io/milvus/blob/master/README.md" }, .trust = 0.8 },
    .{ .name = "pgvector", .pack = packUrl("pgvector"), .tags = &.{ "pgvector", "postgres vector extension", "vector similarity search", "word embedding" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Vector_database", "https://github.com/pgvector/pgvector/blob/master/README.md" }, .trust = 0.8 },
    .{ .name = "faiss", .pack = packUrl("faiss"), .tags = &.{ "faiss", "similarity search library", "approximate nearest neighbor", "product quantization" }, .seeds = &.{ "https://en.wikipedia.org/wiki/FAISS", "https://faiss.ai/" }, .trust = 0.8 },
    .{ .name = "redis-cache", .pack = packUrl("redis-cache"), .tags = &.{ "redis", "in-memory data store", "key-value cache", "in-memory database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Redis", "https://redis.io/docs/latest/" }, .trust = 0.8 },
    .{ .name = "aws-lambda", .pack = packUrl("aws-lambda"), .tags = &.{ "aws lambda", "serverless function", "lambda function", "function as a service" }, .seeds = &.{ "https://en.wikipedia.org/wiki/AWS_Lambda" }, .trust = 0.8 },
    .{ .name = "aws-s3", .pack = packUrl("aws-s3"), .tags = &.{ "aws s3", "amazon s3", "object storage", "cloud bucket" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Amazon_S3" }, .trust = 0.8 },
    .{ .name = "aws-dynamodb", .pack = packUrl("aws-dynamodb"), .tags = &.{ "aws dynamodb", "amazon dynamodb", "nosql database", "key-value store" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Amazon_DynamoDB" }, .trust = 0.8 },
    .{ .name = "cloudflare-workers", .pack = packUrl("cloudflare-workers"), .tags = &.{ "cloudflare workers", "edge functions", "edge serverless", "workers runtime" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cloudflare" }, .trust = 0.8 },
    .{ .name = "serverless-framework", .pack = packUrl("serverless-framework"), .tags = &.{ "serverless framework", "serverless deployment", "function as a service", "iac framework" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Serverless_computing" }, .trust = 0.8 },
    .{ .name = "angular", .pack = packUrl("angular"), .tags = &.{ "angular framework", "angularjs", "angular component", "typescript spa" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Angular_(web_framework)", "https://developer.mozilla.org/en-US/docs/Glossary/SPA" }, .trust = 0.8 },
    .{ .name = "nextjs", .pack = packUrl("nextjs"), .tags = &.{ "next.js", "nextjs", "server-side rendering", "static site generator", "react ssr" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Next.js", "https://developer.mozilla.org/en-US/docs/Glossary/SSR" }, .trust = 0.8 },
    .{ .name = "tailwind-css", .pack = packUrl("tailwind-css"), .tags = &.{ "tailwind css", "utility-first css", "tailwind utility classes", "atomic css" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Tailwind_CSS", "https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Styling_basics" }, .trust = 0.8 },
    .{ .name = "webpack", .pack = packUrl("webpack"), .tags = &.{ "webpack bundler", "webpack loader", "webpack bundle", "module bundler config" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Webpack", "https://developer.mozilla.org/en-US/docs/Glossary/Tree_shaking" }, .trust = 0.8 },
    .{ .name = "vite-build", .pack = packUrl("vite-build"), .tags = &.{ "vite build", "vite dev server", "esm bundler", "vite hmr" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Vite", "https://vitejs.dev/guide/why" }, .trust = 0.8 },
    .{ .name = "spring-boot", .pack = packUrl("spring-boot"), .tags = &.{ "spring boot", "spring framework", "java backend", "spring security" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Spring_Boot", "https://docs.spring.io/spring-boot/index.html" }, .trust = 0.8 },
    .{ .name = "laravel", .pack = packUrl("laravel"), .tags = &.{ "laravel framework", "eloquent orm", "php framework", "blade templating" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Laravel", "https://laravel.com/docs/11.x/routing" }, .trust = 0.8 },
    .{ .name = "aspnet-core", .pack = packUrl("aspnet-core"), .tags = &.{ "asp.net core", "asp.net mvc", "dotnet web", "razor pages" }, .seeds = &.{ "https://en.wikipedia.org/wiki/ASP.NET_Core" }, .trust = 0.8 },
    .{ .name = "sqlalchemy", .pack = packUrl("sqlalchemy"), .tags = &.{ "sqlalchemy orm", "sqlalchemy core", "python orm", "declarative mapping" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SQLAlchemy", "https://docs.sqlalchemy.org/en/20/orm/quickstart.html" }, .trust = 0.8 },
    .{ .name = "hibernate-orm", .pack = packUrl("hibernate-orm"), .tags = &.{ "hibernate orm", "jpa persistence", "hql query", "java persistence" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Hibernate_(framework)", "https://hibernate.org/orm/documentation/getting-started/" }, .trust = 0.8 },
    .{ .name = "prometheus-monitoring", .pack = packUrl("prometheus-monitoring"), .tags = &.{ "prometheus metrics", "metrics monitoring", "time-series metrics", "promql query" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Prometheus_(software)", "https://prometheus.io/docs/introduction/overview/" }, .trust = 0.8 },
    .{ .name = "grafana", .pack = packUrl("grafana"), .tags = &.{ "grafana dashboard", "metrics dashboard", "data visualization", "observability dashboard" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Grafana", "https://grafana.com/docs/grafana/latest/" }, .trust = 0.8 },
    .{ .name = "helm-charts", .pack = packUrl("helm-charts"), .tags = &.{ "helm chart", "helm package manager", "kubernetes package", "chart template" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Helm_(package_manager)", "https://helm.sh/docs/" }, .trust = 0.8 },
    .{ .name = "argocd", .pack = packUrl("argocd"), .tags = &.{ "argo cd", "gitops continuous delivery", "kubernetes continuous delivery", "declarative deployment" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Continuous_delivery", "https://argo-cd.readthedocs.io/en/stable/" }, .trust = 0.8 },
    .{ .name = "opentelemetry", .pack = packUrl("opentelemetry"), .tags = &.{ "opentelemetry instrumentation", "distributed tracing", "observability instrumentation", "telemetry signals" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cloud_Native_Computing_Foundation", "https://opentelemetry.io/docs/" }, .trust = 0.8 },
    .{ .name = "linux-kernel", .pack = packUrl("linux-kernel"), .tags = &.{ "linux kernel", "loadable kernel module", "monolithic kernel", "kernel preemption" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Linux_kernel" }, .trust = 0.8 },
    .{ .name = "ebpf", .pack = packUrl("ebpf"), .tags = &.{ "ebpf", "berkeley packet filter", "xdp", "express data path", "kernel tracing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/EBPF", "https://man7.org/linux/man-pages/man2/bpf.2.html" }, .trust = 0.8 },
    .{ .name = "quic-protocol", .pack = packUrl("quic-protocol"), .tags = &.{ "quic protocol", "quic transport", "udp transport", "connection migration" }, .seeds = &.{ "https://en.wikipedia.org/wiki/QUIC", "https://www.rfc-editor.org/rfc/rfc9000.html" }, .trust = 0.8 },
    .{ .name = "http3-protocol", .pack = packUrl("http3-protocol"), .tags = &.{ "http/3", "http3", "http over quic", "head-of-line blocking" }, .seeds = &.{ "https://en.wikipedia.org/wiki/HTTP/3", "https://www.rfc-editor.org/rfc/rfc9114.html" }, .trust = 0.8 },
    .{ .name = "zfs-filesystem", .pack = packUrl("zfs-filesystem"), .tags = &.{ "zfs", "openzfs", "raid-z", "copy-on-write filesystem", "data scrubbing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/ZFS" }, .trust = 0.8 },
    .{ .name = "wireguard", .pack = packUrl("wireguard"), .tags = &.{ "wireguard", "curve25519", "noise protocol framework", "chacha20-poly1305", "perfect forward secrecy" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WireGuard" }, .trust = 0.8 },
    .{ .name = "mitre-attack", .pack = packUrl("mitre-attack"), .tags = &.{ "mitre att&ck", "adversary tactics techniques", "att&ck framework", "cyber kill chain", "threat actor behavior" }, .seeds = &.{ "https://en.wikipedia.org/wiki/MITRE_ATT%26CK", "https://attack.mitre.org/groups/" }, .trust = 0.8 },
    .{ .name = "zero-trust", .pack = packUrl("zero-trust"), .tags = &.{ "zero trust", "zero trust architecture", "never trust always verify", "principle of least privilege", "software defined perimeter" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Zero_trust_architecture" }, .trust = 0.8 },
    .{ .name = "threat-modeling", .pack = packUrl("threat-modeling"), .tags = &.{ "threat modeling", "attack surface analysis", "attack tree", "data flow diagram", "stride threat model" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Threat_model", "https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html" }, .trust = 0.8 },
    .{ .name = "webauthn-fido2", .pack = packUrl("webauthn-fido2"), .tags = &.{ "webauthn", "fido2 authentication", "fido alliance", "client to authenticator protocol", "hardware security key" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WebAuthn" }, .trust = 0.8 },
    .{ .name = "public-key-infrastructure", .pack = packUrl("public-key-infrastructure"), .tags = &.{ "public key infrastructure", "certificate authority", "certificate revocation list", "online certificate status protocol", "trust service provider" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Public_key_infrastructure" }, .trust = 0.8 },
    .{ .name = "penetration-testing-methodology", .pack = packUrl("penetration-testing-methodology"), .tags = &.{ "penetration testing", "red team assessment", "vulnerability scanner", "security exploit", "open source intelligence" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Penetration_test" }, .trust = 0.8 },
    .{ .name = "incident-response", .pack = packUrl("incident-response"), .tags = &.{ "incident response", "computer security incident", "computer emergency response team", "business continuity planning", "root cause analysis" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Incident_response" }, .trust = 0.8 },
    .{ .name = "ethereum", .pack = packUrl("ethereum"), .tags = &.{ "ethereum", "ether cryptocurrency", "vitalik buterin", "ethereum account" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ethereum", "https://ethereum.org/en/developers/docs/accounts/" }, .trust = 0.8 },
    .{ .name = "bitcoin", .pack = packUrl("bitcoin"), .tags = &.{ "bitcoin", "btc", "bitcoin protocol", "utxo model", "satoshi nakamoto" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Bitcoin" }, .trust = 0.8 },
    .{ .name = "solidity-lang", .pack = packUrl("solidity-lang"), .tags = &.{ "solidity", "solidity contract", "solidity types", "contract inheritance" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Solidity", "https://docs.soliditylang.org/en/latest/introduction-to-smart-contracts.html" }, .trust = 0.8 },
    .{ .name = "smart-contracts", .pack = packUrl("smart-contracts"), .tags = &.{ "smart contract", "on-chain code", "contract execution", "dapp" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Smart_contract", "https://ethereum.org/en/developers/docs/smart-contracts/" }, .trust = 0.8 },
    .{ .name = "zero-knowledge-proofs", .pack = packUrl("zero-knowledge-proofs"), .tags = &.{ "zero-knowledge proof", "zkp", "zk rollup", "prover verifier" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Zero-knowledge_proof", "https://ethereum.org/en/developers/docs/scaling/zk-rollups/" }, .trust = 0.8 },
    .{ .name = "quantum-computing", .pack = packUrl("quantum-computing"), .tags = &.{ "quantum computing", "quantum logic gate", "quantum entanglement", "quantum circuit" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Quantum_computing" }, .trust = 0.8 },
    .{ .name = "probability-theory", .pack = packUrl("probability-theory"), .tags = &.{ "probability theory", "random variable", "probability space", "law of large numbers" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Probability_theory" }, .trust = 0.8 },
    .{ .name = "group-theory", .pack = packUrl("group-theory"), .tags = &.{ "group theory", "abstract algebra", "symmetry group", "abelian group" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Group_(mathematics)" }, .trust = 0.8 },
    .{ .name = "graph-algorithms", .pack = packUrl("graph-algorithms"), .tags = &.{ "graph algorithms", "breadth-first search", "shortest path", "minimum spanning tree" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Graph_(abstract_data_type)" }, .trust = 0.8 },
    .{ .name = "elliptic-curve-cryptography", .pack = packUrl("elliptic-curve-cryptography"), .tags = &.{ "elliptic curve cryptography", "elliptic curve", "discrete logarithm", "digital signature algorithm" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Elliptic-curve_cryptography" }, .trust = 0.8 },
    .{ .name = "jest-testing", .pack = packUrl("jest-testing"), .tags = &.{ "jest testing", "javascript testing", "test runner", "mock functions" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Test_automation", "https://jestjs.io/docs/getting-started" }, .trust = 0.8 },
    .{ .name = "playwright-testing", .pack = packUrl("playwright-testing"), .tags = &.{ "playwright testing", "browser automation", "end-to-end testing", "web locators" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Playwright_(software)", "https://playwright.dev/docs/intro" }, .trust = 0.8 },
    .{ .name = "pytest-testing", .pack = packUrl("pytest-testing"), .tags = &.{ "pytest python", "test fixtures", "python testing", "parametrized tests" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Pytest", "https://docs.pytest.org/en/stable/how-to/fixtures.html" }, .trust = 0.8 },
    // — mega-pack wave 4: applied/scientific/standards long tail — big-data & analytics,
    // AI model architectures, gamedev, graphics/media codecs, protocol standards, advanced
    // defensive security (DFIR/RE/PQC), platform+OS internals, hardware/EDA, verticals
    // (health/finance/GIS/telecom/automotive), scientific computing, advanced web, and DSL/
    // compiler infra. Registry tags, bare-word filtered; trust 0.8. —
    .{ .name = "apache-spark", .pack = packUrl("apache-spark"), .tags = &.{ "apache spark", "spark rdd", "distributed data processing", "map reduce", "in memory computing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Spark", "https://spark.apache.org/docs/latest/" }, .trust = 0.8 },
    .{ .name = "apache-flink", .pack = packUrl("apache-flink"), .tags = &.{ "apache flink", "stream processing", "complex event processing", "stateful streaming", "event time" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Flink", "https://flink.apache.org/" }, .trust = 0.8 },
    .{ .name = "apache-airflow", .pack = packUrl("apache-airflow"), .tags = &.{ "apache airflow", "workflow orchestration", "directed acyclic graph", "task scheduling", "pipeline automation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Airflow", "https://airflow.apache.org/docs/" }, .trust = 0.8 },
    .{ .name = "dbt-transform", .pack = packUrl("dbt-transform"), .tags = &.{ "data build tool", "sql transformation", "analytics engineering", "elt modeling", "materialized view" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Data_build_tool", "https://docs.getdbt.com/" }, .trust = 0.8 },
    .{ .name = "delta-lake", .pack = packUrl("delta-lake"), .tags = &.{ "delta lake", "acid data lake", "snapshot isolation", "transaction log", "open table format" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Delta_Lake", "https://delta.io/" }, .trust = 0.8 },
    .{ .name = "apache-iceberg", .pack = packUrl("apache-iceberg"), .tags = &.{ "apache iceberg", "open table format", "schema evolution", "hidden partitioning", "data lakehouse" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Iceberg", "https://iceberg.apache.org/docs/latest/" }, .trust = 0.8 },
    .{ .name = "apache-arrow", .pack = packUrl("apache-arrow"), .tags = &.{ "apache arrow", "in memory columnar", "zero copy interchange", "vectorized execution", "single instruction multiple data" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Arrow", "https://arrow.apache.org/docs/" }, .trust = 0.8 },
    .{ .name = "polars", .pack = packUrl("polars"), .tags = &.{ "polars dataframe", "rust dataframe library", "lazy query engine", "vectorized execution", "lazy evaluation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Polars_(software)", "https://docs.pola.rs/" }, .trust = 0.8 },
    .{ .name = "apache-beam", .pack = packUrl("apache-beam"), .tags = &.{ "apache beam", "dataflow programming", "unified batch streaming", "data pipeline", "windowing semantics" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Beam" }, .trust = 0.8 },
    .{ .name = "apache-kafka-streams", .pack = packUrl("apache-kafka-streams"), .tags = &.{ "kafka streams", "stream processing library", "stateful stream processing", "event driven microservices", "apache kafka" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Kafka_Streams", "https://kafka.apache.org/documentation/streams/" }, .trust = 0.8 },
    .{ .name = "bert-model", .pack = packUrl("bert-model"), .tags = &.{ "bert model", "bidirectional transformer", "masked language model", "pretrained encoder" }, .seeds = &.{ "https://en.wikipedia.org/wiki/BERT_(language_model)" }, .trust = 0.8 },
    .{ .name = "gpt-architecture", .pack = packUrl("gpt-architecture"), .tags = &.{ "gpt architecture", "generative pretrained transformer", "autoregressive language model", "decoder only model" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Generative_pre-trained_transformer" }, .trust = 0.8 },
    .{ .name = "vision-transformer", .pack = packUrl("vision-transformer"), .tags = &.{ "vision transformer", "image classification model", "patch embedding", "self attention vision" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Vision_transformer" }, .trust = 0.8 },
    .{ .name = "diffusion-models", .pack = packUrl("diffusion-models"), .tags = &.{ "diffusion model", "denoising diffusion", "score based model", "generative markov process" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Diffusion_model" }, .trust = 0.8 },
    .{ .name = "lora-peft", .pack = packUrl("lora-peft"), .tags = &.{ "low rank adaptation", "parameter efficient tuning", "adapter fine tuning", "rank decomposition" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Fine-tuning_(deep_learning)" }, .trust = 0.8 },
    .{ .name = "model-serving", .pack = packUrl("model-serving"), .tags = &.{ "model serving", "inference deployment", "request batching", "prediction endpoint" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Inference_engine" }, .trust = 0.8 },
    .{ .name = "model-context-protocol", .pack = packUrl("model-context-protocol"), .tags = &.{ "model context protocol", "tool calling standard", "json rpc interface", "llm interoperability" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Model_Context_Protocol" }, .trust = 0.8 },
    .{ .name = "gradient-boosting", .pack = packUrl("gradient-boosting"), .tags = &.{ "gradient boosting", "boosted decision trees", "additive model training", "xgboost library" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Gradient_boosting" }, .trust = 0.8 },
    .{ .name = "random-forest", .pack = packUrl("random-forest"), .tags = &.{ "random forest", "decision tree ensemble", "bootstrap aggregating", "feature bagging" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Random_forest" }, .trust = 0.8 },
    .{ .name = "support-vector-machine", .pack = packUrl("support-vector-machine"), .tags = &.{ "support vector machine", "maximum margin classifier", "kernel trick", "separating hyperplane" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Support_vector_machine" }, .trust = 0.8 },
    .{ .name = "principal-component-analysis", .pack = packUrl("principal-component-analysis"), .tags = &.{ "principal component analysis", "singular value decomposition", "eigenvalue decomposition", "variance projection" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Principal_component_analysis" }, .trust = 0.8 },
    .{ .name = "bayesian-inference", .pack = packUrl("bayesian-inference"), .tags = &.{ "bayesian inference", "posterior probability", "prior distribution", "probabilistic reasoning" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Bayesian_inference" }, .trust = 0.8 },
    .{ .name = "deep-reinforcement-learning", .pack = packUrl("deep-reinforcement-learning"), .tags = &.{ "deep reinforcement learning", "reward maximization", "policy learning", "agent environment loop" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Deep_reinforcement_learning" }, .trust = 0.8 },
    .{ .name = "unity-engine", .pack = packUrl("unity-engine"), .tags = &.{ "unity engine", "unity game engine", "unity3d", "unity component" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Unity_(game_engine)" }, .trust = 0.8 },
    .{ .name = "unreal-engine", .pack = packUrl("unreal-engine"), .tags = &.{ "unreal engine", "unreal game engine", "epic games engine", "unreal blueprint" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Unreal_Engine" }, .trust = 0.8 },
    .{ .name = "game-networking", .pack = packUrl("game-networking"), .tags = &.{ "game networking", "netcode", "multiplayer networking", "network game architecture" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Netcode" }, .trust = 0.8 },
    .{ .name = "behavior-trees", .pack = packUrl("behavior-trees"), .tags = &.{ "behavior tree", "behaviour tree ai", "game ai behavior", "behavior tree node" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Behavior_tree_(artificial_intelligence,_robotics_and_control)" }, .trust = 0.8 },
    .{ .name = "box2d-physics", .pack = packUrl("box2d-physics"), .tags = &.{ "box2d physics", "box2d engine", "2d physics library", "box2d body" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Box2D" }, .trust = 0.8 },
    .{ .name = "procedural-generation-games", .pack = packUrl("procedural-generation-games"), .tags = &.{ "procedural generation", "procedural content generation", "roguelike generation", "seeded generation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Procedural_generation" }, .trust = 0.8 },
    .{ .name = "directx-graphics", .pack = packUrl("directx-graphics"), .tags = &.{ "directx api", "direct3d", "hlsl shader", "directx raytracing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DirectX" }, .trust = 0.8 },
    .{ .name = "metal-api", .pack = packUrl("metal-api"), .tags = &.{ "metal api", "apple metal", "metal shading language", "metal gpu" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Metal_(API)" }, .trust = 0.8 },
    .{ .name = "webgpu-api", .pack = packUrl("webgpu-api"), .tags = &.{ "webgpu api", "browser gpu", "gpu compute web", "webgpu device" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WebGPU", "https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API" }, .trust = 0.8 },
    .{ .name = "ray-tracing-rt", .pack = packUrl("ray-tracing-rt"), .tags = &.{ "ray tracing", "ray tracing hardware", "rtx gpu", "bvh acceleration" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ray_tracing_(graphics)" }, .trust = 0.8 },
    .{ .name = "physically-based-rendering", .pack = packUrl("physically-based-rendering"), .tags = &.{ "physically based rendering", "pbr material", "microfacet model", "fresnel reflectance" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Physically_based_rendering" }, .trust = 0.8 },
    .{ .name = "ffmpeg", .pack = packUrl("ffmpeg"), .tags = &.{ "ffmpeg tool", "libavcodec", "video transcoding", "media conversion" }, .seeds = &.{ "https://en.wikipedia.org/wiki/FFmpeg" }, .trust = 0.8 },
    .{ .name = "video-codec-h264", .pack = packUrl("video-codec-h264"), .tags = &.{ "h.264 codec", "advanced video coding", "cabac entropy", "motion compensation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Advanced_Video_Coding" }, .trust = 0.8 },
    .{ .name = "av1-codec", .pack = packUrl("av1-codec"), .tags = &.{ "av1 codec", "aomedia video", "royalty-free codec", "av1 encoding" }, .seeds = &.{ "https://en.wikipedia.org/wiki/AV1" }, .trust = 0.8 },
    .{ .name = "gltf-format", .pack = packUrl("gltf-format"), .tags = &.{ "gltf format", "khronos gltf", "3d asset transmission", "pbr gltf" }, .seeds = &.{ "https://en.wikipedia.org/wiki/GlTF" }, .trust = 0.8 },
    .{ .name = "opus-codec", .pack = packUrl("opus-codec"), .tags = &.{ "opus audio", "celt codec", "silk speech", "voip audio codec" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Opus_(audio_format)" }, .trust = 0.8 },
    .{ .name = "json-schema", .pack = packUrl("json-schema"), .tags = &.{ "json schema", "schema validation", "json validation", "data contract" }, .seeds = &.{ "https://en.wikipedia.org/wiki/JSON", "https://json-schema.org/understanding-json-schema/" }, .trust = 0.8 },
    .{ .name = "apache-avro", .pack = packUrl("apache-avro"), .tags = &.{ "apache avro", "row oriented serialization", "schema registry", "compact binary format", "remote procedure call" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Avro" }, .trust = 0.8 },
    .{ .name = "openid-connect", .pack = packUrl("openid-connect"), .tags = &.{ "openid connect", "oidc protocol", "id token authentication", "oauth identity layer" }, .seeds = &.{ "https://en.wikipedia.org/wiki/OpenID_Connect" }, .trust = 0.8 },
    .{ .name = "saml-federation", .pack = packUrl("saml-federation"), .tags = &.{ "saml federation", "security assertion markup language", "saml assertion", "browser sso federation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Security_Assertion_Markup_Language" }, .trust = 0.8 },
    .{ .name = "server-sent-events", .pack = packUrl("server-sent-events"), .tags = &.{ "server-sent events", "sse streaming", "eventsource api", "http push stream" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Server-sent_events" }, .trust = 0.8 },
    .{ .name = "sparql-query", .pack = packUrl("sparql-query"), .tags = &.{ "sparql query language", "rdf query language", "semantic web query", "triple pattern query" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SPARQL" }, .trust = 0.8 },
    .{ .name = "cypher-query", .pack = packUrl("cypher-query"), .tags = &.{ "cypher query language", "neo4j cypher", "graph pattern query", "property graph query" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cypher_(query_language)" }, .trust = 0.8 },
    .{ .name = "promql", .pack = packUrl("promql"), .tags = &.{ "promql query", "prometheus query language", "time-series query", "metrics query language" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Prometheus_(software)" }, .trust = 0.8 },
    .{ .name = "protocol-buffers-idl", .pack = packUrl("protocol-buffers-idl"), .tags = &.{ "protocol buffers", "protobuf idl", "interface description language", "binary serialization schema" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Protocol_Buffers", "https://protobuf.dev/" }, .trust = 0.8 },
    .{ .name = "yara-rules", .pack = packUrl("yara-rules"), .tags = &.{ "yara rules", "malware signature", "pattern matching detection", "antivirus engine", "signature based detection" }, .seeds = &.{ "https://en.wikipedia.org/wiki/YARA" }, .trust = 0.8 },
    .{ .name = "sigma-detection-rules", .pack = packUrl("sigma-detection-rules"), .tags = &.{ "sigma detection rules", "log detection format", "detection engineering", "rule based system", "security event correlation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Rule-based_system" }, .trust = 0.8 },
    .{ .name = "suricata-ids", .pack = packUrl("suricata-ids"), .tags = &.{ "suricata ids", "network intrusion detection", "deep packet inspection", "intrusion prevention system", "packet capture analysis" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Suricata_(software)" }, .trust = 0.8 },
    .{ .name = "threat-hunting", .pack = packUrl("threat-hunting"), .tags = &.{ "cyber threat hunting", "proactive threat detection", "indicator of compromise", "advanced persistent threat", "hypothesis driven investigation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cyber_threat_hunting" }, .trust = 0.8 },
    .{ .name = "post-quantum-cryptography", .pack = packUrl("post-quantum-cryptography"), .tags = &.{ "post quantum cryptography", "quantum resistant algorithm", "shor algorithm threat", "nist pqc standardization", "quantum safe encryption" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Post-quantum_cryptography" }, .trust = 0.8 },
    .{ .name = "memory-forensics-volatility", .pack = packUrl("memory-forensics-volatility"), .tags = &.{ "memory forensics volatility", "volatile memory acquisition", "process memory dump analysis", "core dump inspection", "digital evidence recovery" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Memory_forensics" }, .trust = 0.8 },
    .{ .name = "reverse-engineering-ghidra", .pack = packUrl("reverse-engineering-ghidra"), .tags = &.{ "ghidra reverse engineering", "software reverse engineering", "binary decompiler analysis", "disassembly workflow", "malware code analysis" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ghidra" }, .trust = 0.8 },
    .{ .name = "confidential-computing", .pack = packUrl("confidential-computing"), .tags = &.{ "confidential computing", "data in use protection", "trusted execution environment", "encrypted memory enclave", "hardware attestation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Confidential_computing" }, .trust = 0.8 },
    .{ .name = "win32-api", .pack = packUrl("win32-api"), .tags = &.{ "win32 api", "windows api", "windows programming", "dynamic-link library" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Windows_API" }, .trust = 0.8 },
    .{ .name = "cocoa-framework", .pack = packUrl("cocoa-framework"), .tags = &.{ "cocoa framework", "cocoa api", "objective-c runtime", "interface builder" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cocoa_(API)" }, .trust = 0.8 },
    .{ .name = "jetpack-compose", .pack = packUrl("jetpack-compose"), .tags = &.{ "jetpack compose", "declarative ui", "kotlin language", "android development" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Jetpack_Compose" }, .trust = 0.8 },
    .{ .name = "swiftui-framework", .pack = packUrl("swiftui-framework"), .tags = &.{ "swiftui framework", "swift language", "declarative ui", "data binding" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SwiftUI" }, .trust = 0.8 },
    .{ .name = "debian-linux", .pack = packUrl("debian-linux"), .tags = &.{ "debian linux", "apt package manager", "dpkg tool", "debian release" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Debian" }, .trust = 0.8 },
    .{ .name = "wayland-protocol", .pack = packUrl("wayland-protocol"), .tags = &.{ "wayland protocol", "wayland compositor", "weston reference", "display server" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Wayland_(protocol)" }, .trust = 0.8 },
    .{ .name = "wasm-toolchain", .pack = packUrl("wasm-toolchain"), .tags = &.{ "webassembly toolchain", "wasm bytecode", "wasm stack machine", "wasm binary format" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WebAssembly", "https://webassembly.org/" }, .trust = 0.8 },
    .{ .name = "systemverilog", .pack = packUrl("systemverilog"), .tags = &.{ "systemverilog language", "hardware verification language", "rtl verification", "hardware description language" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SystemVerilog" }, .trust = 0.8 },
    .{ .name = "uvm-verification", .pack = packUrl("uvm-verification"), .tags = &.{ "uvm methodology", "universal verification methodology", "functional verification", "constrained random testing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Universal_Verification_Methodology" }, .trust = 0.8 },
    .{ .name = "rtl-synthesis", .pack = packUrl("rtl-synthesis"), .tags = &.{ "rtl synthesis", "logic synthesis", "technology mapping", "gate netlist" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Logic_synthesis" }, .trust = 0.8 },
    .{ .name = "spice-simulation", .pack = packUrl("spice-simulation"), .tags = &.{ "spice simulation", "circuit simulation", "netlist analysis", "transistor modeling" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SPICE" }, .trust = 0.8 },
    .{ .name = "cpu-microarchitecture", .pack = packUrl("cpu-microarchitecture"), .tags = &.{ "cpu microarchitecture", "instruction pipelining", "risc pipeline stages", "processor datapath" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Microarchitecture" }, .trust = 0.8 },
    .{ .name = "gpu-microarchitecture", .pack = packUrl("gpu-microarchitecture"), .tags = &.{ "gpu microarchitecture", "stream processing", "single instruction multiple threads", "shader cores" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Graphics_processing_unit" }, .trust = 0.8 },
    .{ .name = "fhir-health", .pack = packUrl("fhir-health"), .tags = &.{ "fhir standard", "health interoperability", "hl7 fhir", "electronic health record" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Fast_Healthcare_Interoperability_Resources" }, .trust = 0.8 },
    .{ .name = "dicom-imaging", .pack = packUrl("dicom-imaging"), .tags = &.{ "dicom imaging", "medical imaging", "picture archiving", "radiology information" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DICOM" }, .trust = 0.8 },
    .{ .name = "quantitative-finance", .pack = packUrl("quantitative-finance"), .tags = &.{ "quantitative finance", "mathematical finance", "financial modeling", "derivatives pricing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Quantitative_analysis_(finance)" }, .trust = 0.8 },
    .{ .name = "geospatial-gis", .pack = packUrl("geospatial-gis"), .tags = &.{ "geospatial gis", "spatial analysis", "geographic information", "digital cartography" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Geographic_information_system" }, .trust = 0.8 },
    .{ .name = "postgis", .pack = packUrl("postgis"), .tags = &.{ "postgis spatial", "spatial database", "geometry storage", "well known text" }, .seeds = &.{ "https://en.wikipedia.org/wiki/PostGIS", "https://postgis.net/documentation/" }, .trust = 0.8 },
    .{ .name = "wordpress-cms", .pack = packUrl("wordpress-cms"), .tags = &.{ "wordpress cms", "content management system", "wordpress plugin", "wordpress theme" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WordPress" }, .trust = 0.8 },
    .{ .name = "telecom-5g", .pack = packUrl("telecom-5g"), .tags = &.{ "5g network", "5g new radio", "network slicing", "millimeter wave 5g" }, .seeds = &.{ "https://en.wikipedia.org/wiki/5G" }, .trust = 0.8 },
    .{ .name = "automotive-autosar", .pack = packUrl("automotive-autosar"), .tags = &.{ "autosar architecture", "automotive software", "electronic control unit", "automotive rtos" }, .seeds = &.{ "https://en.wikipedia.org/wiki/AUTOSAR" }, .trust = 0.8 },
    .{ .name = "digital-twin", .pack = packUrl("digital-twin"), .tags = &.{ "digital twin", "cyber physical system", "simulation model", "predictive maintenance twin" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Digital_twin" }, .trust = 0.8 },
    .{ .name = "scipy-library", .pack = packUrl("scipy-library"), .tags = &.{ "scipy library", "scientific python", "numerical routines", "signal processing scipy" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SciPy", "https://docs.scipy.org/doc/scipy/tutorial/index.html" }, .trust = 0.8 },
    .{ .name = "sympy-symbolic", .pack = packUrl("sympy-symbolic"), .tags = &.{ "sympy symbolic", "computer algebra", "symbolic integration", "equation solving" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SymPy", "https://docs.sympy.org/latest/tutorials/intro-tutorial/index.html" }, .trust = 0.8 },
    .{ .name = "quantum-chemistry-dft", .pack = packUrl("quantum-chemistry-dft"), .tags = &.{ "quantum chemistry", "electronic structure", "coupled cluster", "configuration interaction" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Quantum_chemistry" }, .trust = 0.8 },
    .{ .name = "high-performance-computing", .pack = packUrl("high-performance-computing"), .tags = &.{ "high-performance computing", "parallel computing", "amdahl law", "gpu general-purpose computing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/High-performance_computing" }, .trust = 0.8 },
    .{ .name = "mpi-parallel-computing", .pack = packUrl("mpi-parallel-computing"), .tags = &.{ "message passing interface", "distributed memory parallelism", "process communication mpi", "collective communication" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Message_Passing_Interface", "https://mpi4py.readthedocs.io/en/stable/" }, .trust = 0.8 },
    .{ .name = "agent-based-modeling", .pack = packUrl("agent-based-modeling"), .tags = &.{ "agent-based model", "complex adaptive system", "swarm intelligence", "segregation model" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Agent-based_model" }, .trust = 0.8 },
    .{ .name = "content-security-policy", .pack = packUrl("content-security-policy"), .tags = &.{ "content security policy", "csp header", "xss mitigation", "script-src directive", "default-src fallback" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Content_Security_Policy", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP" }, .trust = 0.8 },
    .{ .name = "cross-origin-resource-sharing", .pack = packUrl("cross-origin-resource-sharing"), .tags = &.{ "cross-origin resource sharing", "cors preflight request", "access-control-allow-origin header", "credentialed cross-origin request" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cross-origin_resource_sharing", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS" }, .trust = 0.8 },
    .{ .name = "core-web-vitals", .pack = packUrl("core-web-vitals"), .tags = &.{ "core web vitals", "largest contentful paint", "cumulative layout shift", "performance observer entry" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Web_performance", "https://developer.mozilla.org/en-US/docs/Web/API/Largest_Contentful_Paint_API" }, .trust = 0.8 },
    .{ .name = "server-side-rendering-web", .pack = packUrl("server-side-rendering-web"), .tags = &.{ "server side rendering", "client side hydration", "dynamic web page", "server-side scripting" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Server-side_scripting", "https://developer.mozilla.org/en-US/docs/Glossary/SSR" }, .trust = 0.8 },
    .{ .name = "micro-frontends", .pack = packUrl("micro-frontends"), .tags = &.{ "micro frontends", "frontend composition", "separation of concerns", "iframe isolation boundary" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Micro_frontend", "https://developer.mozilla.org/en-US/docs/Web/API/Web_components" }, .trust = 0.8 },
    .{ .name = "search-engine-optimization", .pack = packUrl("search-engine-optimization"), .tags = &.{ "search engine optimization", "meta description tag", "canonical link relation", "web crawler indexing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Search_engine_optimization", "https://developer.mozilla.org/en-US/docs/Glossary/SEO" }, .trust = 0.8 },
    .{ .name = "language-server-protocol", .pack = packUrl("language-server-protocol"), .tags = &.{ "language server protocol", "lsp editor tooling", "code intelligence protocol", "json-rpc editor" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Language_Server_Protocol" }, .trust = 0.8 },
    .{ .name = "tree-sitter-parsing", .pack = packUrl("tree-sitter-parsing"), .tags = &.{ "tree-sitter parser", "incremental parsing", "concrete syntax tree", "editor syntax parsing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Tree-sitter_(parser_generator)", "https://tree-sitter.github.io/tree-sitter/" }, .trust = 0.8 },
    .{ .name = "llvm-infrastructure", .pack = packUrl("llvm-infrastructure"), .tags = &.{ "llvm infrastructure", "llvm compiler toolchain", "optimizing compiler backend", "clang frontend" }, .seeds = &.{ "https://en.wikipedia.org/wiki/LLVM", "https://llvm.org/docs/LangRef.html" }, .trust = 0.8 },
    .{ .name = "rego-opa-policy", .pack = packUrl("rego-opa-policy"), .tags = &.{ "rego policy", "open policy agent", "policy as code", "rego datalog rules" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Datalog", "https://www.openpolicyagent.org/docs/latest/policy-language/" }, .trust = 0.8 },
    .{ .name = "turborepo", .pack = packUrl("turborepo"), .tags = &.{ "turborepo monorepo", "turbo build cache", "monorepo task pipeline", "incremental build cache" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Monorepo", "https://turbo.build/repo/docs" }, .trust = 0.8 },
    .{ .name = "jsonnet", .pack = packUrl("jsonnet"), .tags = &.{ "jsonnet language", "data templating language", "json config generation", "google jsonnet" }, .seeds = &.{ "https://en.wikipedia.org/wiki/JSON", "https://jsonnet.org/" }, .trust = 0.8 },
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

test "mega-pack wave 3: framework/security routing fires with packs, generic prose stays silent" {
    const gpa = std.testing.allocator;
    // exact multi-word tags route to their new pack ("cuda programming" is unique to cuda-programming)
    const blk = sourcesBlock(gpa, "write a cuda programming gpu kernel for the quantum computing simulator", 3);
    defer if (blk.len > 0) gpa.free(@constCast(blk));
    try std.testing.expect(std.mem.indexOf(u8, blk, "packs/cuda-programming/INDEX.md") != null);
    // a defensive-security goal reaches the new threat-modeling pack
    var s: [3]*const Loc = undefined;
    const ns = match("run the threat modeling attack surface analysis for this service", &s);
    var saw = false;
    for (s[0..ns]) |l| {
        if (std.mem.eql(u8, l.name, "threat-modeling")) saw = true;
    }
    try std.testing.expect(saw);
    // unrelated prose routes nowhere
    var g: [3]*const Loc = undefined;
    try std.testing.expectEqual(@as(usize, 0), match("bake a chocolate cake and plan the birthday party", &g));
}

test "mega-pack wave 4: data/hardware/health routing fires with packs across verticals" {
    const gpa = std.testing.allocator;
    const b1 = sourcesBlock(gpa, "process the dataset with apache spark and write an iceberg table", 3);
    defer if (b1.len > 0) gpa.free(@constCast(b1));
    try std.testing.expect(std.mem.indexOf(u8, b1, "packs/apache-spark/INDEX.md") != null);
    const b2 = sourcesBlock(gpa, "verify the rtl verification with systemverilog language", 3);
    defer if (b2.len > 0) gpa.free(@constCast(b2));
    try std.testing.expect(std.mem.indexOf(u8, b2, "packs/systemverilog/INDEX.md") != null);
    const b3 = sourcesBlock(gpa, "set a strict content security policy to stop the xss", 3);
    defer if (b3.len > 0) gpa.free(@constCast(b3));
    try std.testing.expect(std.mem.indexOf(u8, b3, "packs/content-security-policy/INDEX.md") != null);
    // a health-IT goal reaches the fhir pack
    var s: [3]*const Loc = undefined;
    const ns = match("expose patient records over a fhir standard api", &s);
    var saw = false;
    for (s[0..ns]) |l| {
        if (std.mem.eql(u8, l.name, "fhir-health")) saw = true;
    }
    try std.testing.expect(saw);
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
