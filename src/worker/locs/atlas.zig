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

/// nl-rag (github.com/gary23w/nl-rag) mirrors curated doc pages as pre-normalized markdown packs — no HTML,
/// no site chrome, frontmattered provenance, split to fetch-sized parts — better input for a small model than
/// the raw doc site. Pack bodies ride the existing 7-day fetch cache, so a page costs one GET. The INDEX lists
/// every pack page (plus a distilled pack.facts) as absolute raw urls. Seeds stay listed: the pack is a fast
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
    .{ .name = "tensorflow", .pack = packUrl("tensorflow"), .tags = &.{ "tensorflow framework", "deep learning framework", "google brain", "dataflow graph", "tpu accelerator" }, .seeds = &.{"https://en.wikipedia.org/wiki/TensorFlow"}, .trust = 0.8 },
    .{ .name = "keras", .pack = packUrl("keras"), .tags = &.{ "keras api", "neural network library", "high level api", "model training" }, .seeds = &.{"https://en.wikipedia.org/wiki/Keras"}, .trust = 0.8 },
    .{ .name = "jax-ml", .pack = packUrl("jax-ml"), .tags = &.{ "jax library", "autograd differentiation", "just in time compilation", "numpy vectorization", "accelerator computing" }, .seeds = &.{"https://en.wikipedia.org/wiki/JAX_(software)"}, .trust = 0.8 },
    .{ .name = "huggingface-transformers", .pack = packUrl("huggingface-transformers"), .tags = &.{ "hugging face", "transformers library", "pretrained model", "language model hub" }, .seeds = &.{"https://en.wikipedia.org/wiki/Hugging_Face"}, .trust = 0.8 },
    .{ .name = "langchain", .pack = packUrl("langchain"), .tags = &.{ "langchain framework", "llm application", "retrieval augmented generation", "prompt chaining", "ai agent" }, .seeds = &.{"https://en.wikipedia.org/wiki/LangChain"}, .trust = 0.8 },
    .{ .name = "llamaindex", .pack = packUrl("llamaindex"), .tags = &.{ "llamaindex framework", "data indexing", "retrieval augmented generation", "document retrieval", "knowledge base" }, .seeds = &.{"https://en.wikipedia.org/wiki/Retrieval-augmented_generation"}, .trust = 0.8 },
    .{ .name = "onnx", .pack = packUrl("onnx"), .tags = &.{ "onnx format", "model interoperability", "inference engine", "neural network exchange" }, .seeds = &.{"https://en.wikipedia.org/wiki/Open_Neural_Network_Exchange"}, .trust = 0.8 },
    .{ .name = "opencv", .pack = packUrl("opencv"), .tags = &.{ "opencv library", "computer vision", "image processing", "feature detection", "optical flow" }, .seeds = &.{"https://en.wikipedia.org/wiki/OpenCV"}, .trust = 0.8 },
    .{ .name = "spacy-nlp", .pack = packUrl("spacy-nlp"), .tags = &.{ "spacy library", "natural language processing", "named entity recognition", "dependency parsing", "part of speech" }, .seeds = &.{"https://en.wikipedia.org/wiki/SpaCy"}, .trust = 0.8 },
    .{ .name = "cuda-programming", .pack = packUrl("cuda-programming"), .tags = &.{ "cuda programming", "gpu computing", "parallel kernel", "nvidia accelerator", "gpgpu" }, .seeds = &.{"https://en.wikipedia.org/wiki/CUDA"}, .trust = 0.8 },
    .{ .name = "rag-systems", .pack = packUrl("rag-systems"), .tags = &.{ "rag pipeline", "retrieval augmented generation", "vector retrieval", "semantic search", "grounded generation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Retrieval-augmented_generation"}, .trust = 0.8 },
    .{ .name = "llm-fine-tuning", .pack = packUrl("llm-fine-tuning"), .tags = &.{ "fine tuning llm", "parameter efficient", "instruction tuning", "domain adaptation", "supervised finetuning" }, .seeds = &.{"https://en.wikipedia.org/wiki/Fine-tuning_(deep_learning)"}, .trust = 0.8 },
    .{ .name = "model-quantization", .pack = packUrl("model-quantization"), .tags = &.{ "model quantization", "low precision", "integer inference", "post training quantization", "weight compression" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantization_(signal_processing)"}, .trust = 0.8 },
    .{ .name = "vector-search", .pack = packUrl("vector-search"), .tags = &.{ "vector search", "nearest neighbor", "approximate search", "similarity search", "vector database" }, .seeds = &.{"https://en.wikipedia.org/wiki/Nearest_neighbor_search"}, .trust = 0.8 },
    .{ .name = "model-embeddings", .pack = packUrl("model-embeddings"), .tags = &.{ "vector embeddings", "word embedding", "sentence embedding", "representation learning", "latent vector" }, .seeds = &.{"https://en.wikipedia.org/wiki/Word_embedding"}, .trust = 0.8 },
    .{ .name = "graph-neural-networks", .pack = packUrl("graph-neural-networks"), .tags = &.{ "graph neural network", "message passing", "node embedding", "graph representation", "relational learning" }, .seeds = &.{"https://en.wikipedia.org/wiki/Graph_neural_network"}, .trust = 0.8 },
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
    .{ .name = "aws-lambda", .pack = packUrl("aws-lambda"), .tags = &.{ "aws lambda", "serverless function", "lambda function", "function as a service" }, .seeds = &.{"https://en.wikipedia.org/wiki/AWS_Lambda"}, .trust = 0.8 },
    .{ .name = "aws-s3", .pack = packUrl("aws-s3"), .tags = &.{ "aws s3", "amazon s3", "object storage", "cloud bucket" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_S3"}, .trust = 0.8 },
    .{ .name = "aws-dynamodb", .pack = packUrl("aws-dynamodb"), .tags = &.{ "aws dynamodb", "amazon dynamodb", "nosql database", "key-value store" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_DynamoDB"}, .trust = 0.8 },
    .{ .name = "cloudflare-workers", .pack = packUrl("cloudflare-workers"), .tags = &.{ "cloudflare workers", "edge functions", "edge serverless", "workers runtime" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cloudflare"}, .trust = 0.8 },
    .{ .name = "serverless-framework", .pack = packUrl("serverless-framework"), .tags = &.{ "serverless framework", "serverless deployment", "function as a service", "iac framework" }, .seeds = &.{"https://en.wikipedia.org/wiki/Serverless_computing"}, .trust = 0.8 },
    .{ .name = "angular", .pack = packUrl("angular"), .tags = &.{ "angular framework", "angularjs", "angular component", "typescript spa" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Angular_(web_framework)", "https://developer.mozilla.org/en-US/docs/Glossary/SPA" }, .trust = 0.8 },
    .{ .name = "nextjs", .pack = packUrl("nextjs"), .tags = &.{ "next.js", "nextjs", "server-side rendering", "static site generator", "react ssr" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Next.js", "https://developer.mozilla.org/en-US/docs/Glossary/SSR" }, .trust = 0.8 },
    .{ .name = "tailwind-css", .pack = packUrl("tailwind-css"), .tags = &.{ "tailwind css", "utility-first css", "tailwind utility classes", "atomic css" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Tailwind_CSS", "https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Styling_basics" }, .trust = 0.8 },
    .{ .name = "webpack", .pack = packUrl("webpack"), .tags = &.{ "webpack bundler", "webpack loader", "webpack bundle", "module bundler config" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Webpack", "https://developer.mozilla.org/en-US/docs/Glossary/Tree_shaking" }, .trust = 0.8 },
    .{ .name = "vite-build", .pack = packUrl("vite-build"), .tags = &.{ "vite build", "vite dev server", "esm bundler", "vite hmr" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Vite", "https://vitejs.dev/guide/why" }, .trust = 0.8 },
    .{ .name = "spring-boot", .pack = packUrl("spring-boot"), .tags = &.{ "spring boot", "spring framework", "java backend", "spring security" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Spring_Boot", "https://docs.spring.io/spring-boot/index.html" }, .trust = 0.8 },
    .{ .name = "laravel", .pack = packUrl("laravel"), .tags = &.{ "laravel framework", "eloquent orm", "php framework", "blade templating" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Laravel", "https://laravel.com/docs/11.x/routing" }, .trust = 0.8 },
    .{ .name = "aspnet-core", .pack = packUrl("aspnet-core"), .tags = &.{ "asp.net core", "asp.net mvc", "dotnet web", "razor pages" }, .seeds = &.{"https://en.wikipedia.org/wiki/ASP.NET_Core"}, .trust = 0.8 },
    .{ .name = "sqlalchemy", .pack = packUrl("sqlalchemy"), .tags = &.{ "sqlalchemy orm", "sqlalchemy core", "python orm", "declarative mapping" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SQLAlchemy", "https://docs.sqlalchemy.org/en/20/orm/quickstart.html" }, .trust = 0.8 },
    .{ .name = "hibernate-orm", .pack = packUrl("hibernate-orm"), .tags = &.{ "hibernate orm", "jpa persistence", "hql query", "java persistence" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Hibernate_(framework)", "https://hibernate.org/orm/documentation/getting-started/" }, .trust = 0.8 },
    .{ .name = "prometheus-monitoring", .pack = packUrl("prometheus-monitoring"), .tags = &.{ "prometheus metrics", "metrics monitoring", "time-series metrics", "promql query" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Prometheus_(software)", "https://prometheus.io/docs/introduction/overview/" }, .trust = 0.8 },
    .{ .name = "grafana", .pack = packUrl("grafana"), .tags = &.{ "grafana dashboard", "metrics dashboard", "data visualization", "observability dashboard" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Grafana", "https://grafana.com/docs/grafana/latest/" }, .trust = 0.8 },
    .{ .name = "helm-charts", .pack = packUrl("helm-charts"), .tags = &.{ "helm chart", "helm package manager", "kubernetes package", "chart template" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Helm_(package_manager)", "https://helm.sh/docs/" }, .trust = 0.8 },
    .{ .name = "argocd", .pack = packUrl("argocd"), .tags = &.{ "argo cd", "gitops continuous delivery", "kubernetes continuous delivery", "declarative deployment" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Continuous_delivery", "https://argo-cd.readthedocs.io/en/stable/" }, .trust = 0.8 },
    .{ .name = "opentelemetry", .pack = packUrl("opentelemetry"), .tags = &.{ "opentelemetry instrumentation", "distributed tracing", "observability instrumentation", "telemetry signals" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cloud_Native_Computing_Foundation", "https://opentelemetry.io/docs/" }, .trust = 0.8 },
    .{ .name = "linux-kernel", .pack = packUrl("linux-kernel"), .tags = &.{ "linux kernel", "loadable kernel module", "monolithic kernel", "kernel preemption" }, .seeds = &.{"https://en.wikipedia.org/wiki/Linux_kernel"}, .trust = 0.8 },
    .{ .name = "ebpf", .pack = packUrl("ebpf"), .tags = &.{ "ebpf", "berkeley packet filter", "xdp", "express data path", "kernel tracing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/EBPF", "https://man7.org/linux/man-pages/man2/bpf.2.html" }, .trust = 0.8 },
    .{ .name = "quic-protocol", .pack = packUrl("quic-protocol"), .tags = &.{ "quic protocol", "quic transport", "udp transport", "connection migration" }, .seeds = &.{ "https://en.wikipedia.org/wiki/QUIC", "https://www.rfc-editor.org/rfc/rfc9000.html" }, .trust = 0.8 },
    .{ .name = "http3-protocol", .pack = packUrl("http3-protocol"), .tags = &.{ "http/3", "http3", "http over quic", "head-of-line blocking" }, .seeds = &.{ "https://en.wikipedia.org/wiki/HTTP/3", "https://www.rfc-editor.org/rfc/rfc9114.html" }, .trust = 0.8 },
    .{ .name = "zfs-filesystem", .pack = packUrl("zfs-filesystem"), .tags = &.{ "zfs", "openzfs", "raid-z", "copy-on-write filesystem", "data scrubbing" }, .seeds = &.{"https://en.wikipedia.org/wiki/ZFS"}, .trust = 0.8 },
    .{ .name = "wireguard", .pack = packUrl("wireguard"), .tags = &.{ "wireguard", "curve25519", "noise protocol framework", "chacha20-poly1305", "perfect forward secrecy" }, .seeds = &.{"https://en.wikipedia.org/wiki/WireGuard"}, .trust = 0.8 },
    .{ .name = "mitre-attack", .pack = packUrl("mitre-attack"), .tags = &.{ "mitre att&ck", "adversary tactics techniques", "att&ck framework", "cyber kill chain", "threat actor behavior" }, .seeds = &.{ "https://en.wikipedia.org/wiki/MITRE_ATT%26CK", "https://attack.mitre.org/groups/" }, .trust = 0.8 },
    .{ .name = "zero-trust", .pack = packUrl("zero-trust"), .tags = &.{ "zero trust", "zero trust architecture", "never trust always verify", "principle of least privilege", "software defined perimeter" }, .seeds = &.{"https://en.wikipedia.org/wiki/Zero_trust_architecture"}, .trust = 0.8 },
    .{ .name = "threat-modeling", .pack = packUrl("threat-modeling"), .tags = &.{ "threat modeling", "attack surface analysis", "attack tree", "data flow diagram", "stride threat model" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Threat_model", "https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html" }, .trust = 0.8 },
    .{ .name = "webauthn-fido2", .pack = packUrl("webauthn-fido2"), .tags = &.{ "webauthn", "fido2 authentication", "fido alliance", "client to authenticator protocol", "hardware security key" }, .seeds = &.{"https://en.wikipedia.org/wiki/WebAuthn"}, .trust = 0.8 },
    .{ .name = "public-key-infrastructure", .pack = packUrl("public-key-infrastructure"), .tags = &.{ "public key infrastructure", "certificate authority", "certificate revocation list", "online certificate status protocol", "trust service provider" }, .seeds = &.{"https://en.wikipedia.org/wiki/Public_key_infrastructure"}, .trust = 0.8 },
    .{ .name = "penetration-testing-methodology", .pack = packUrl("penetration-testing-methodology"), .tags = &.{ "penetration testing", "red team assessment", "vulnerability scanner", "security exploit", "open source intelligence" }, .seeds = &.{"https://en.wikipedia.org/wiki/Penetration_test"}, .trust = 0.8 },
    .{ .name = "incident-response", .pack = packUrl("incident-response"), .tags = &.{ "incident response", "computer security incident", "computer emergency response team", "business continuity planning", "root cause analysis" }, .seeds = &.{"https://en.wikipedia.org/wiki/Incident_response"}, .trust = 0.8 },
    .{ .name = "ethereum", .pack = packUrl("ethereum"), .tags = &.{ "ethereum", "ether cryptocurrency", "vitalik buterin", "ethereum account" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ethereum", "https://ethereum.org/en/developers/docs/accounts/" }, .trust = 0.8 },
    .{ .name = "bitcoin", .pack = packUrl("bitcoin"), .tags = &.{ "bitcoin", "btc", "bitcoin protocol", "utxo model", "satoshi nakamoto" }, .seeds = &.{"https://en.wikipedia.org/wiki/Bitcoin"}, .trust = 0.8 },
    .{ .name = "solidity-lang", .pack = packUrl("solidity-lang"), .tags = &.{ "solidity", "solidity contract", "solidity types", "contract inheritance" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Solidity", "https://docs.soliditylang.org/en/latest/introduction-to-smart-contracts.html" }, .trust = 0.8 },
    .{ .name = "smart-contracts", .pack = packUrl("smart-contracts"), .tags = &.{ "smart contract", "on-chain code", "contract execution", "dapp" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Smart_contract", "https://ethereum.org/en/developers/docs/smart-contracts/" }, .trust = 0.8 },
    .{ .name = "zero-knowledge-proofs", .pack = packUrl("zero-knowledge-proofs"), .tags = &.{ "zero-knowledge proof", "zkp", "zk rollup", "prover verifier" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Zero-knowledge_proof", "https://ethereum.org/en/developers/docs/scaling/zk-rollups/" }, .trust = 0.8 },
    .{ .name = "quantum-computing", .pack = packUrl("quantum-computing"), .tags = &.{ "quantum computing", "quantum logic gate", "quantum entanglement", "quantum circuit" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantum_computing"}, .trust = 0.8 },
    .{ .name = "probability-theory", .pack = packUrl("probability-theory"), .tags = &.{ "probability theory", "random variable", "probability space", "law of large numbers" }, .seeds = &.{"https://en.wikipedia.org/wiki/Probability_theory"}, .trust = 0.8 },
    .{ .name = "group-theory", .pack = packUrl("group-theory"), .tags = &.{ "group theory", "abstract algebra", "symmetry group", "abelian group" }, .seeds = &.{"https://en.wikipedia.org/wiki/Group_(mathematics)"}, .trust = 0.8 },
    .{ .name = "graph-algorithms", .pack = packUrl("graph-algorithms"), .tags = &.{ "graph algorithms", "breadth-first search", "shortest path", "minimum spanning tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/Graph_(abstract_data_type)"}, .trust = 0.8 },
    .{ .name = "elliptic-curve-cryptography", .pack = packUrl("elliptic-curve-cryptography"), .tags = &.{ "elliptic curve cryptography", "elliptic curve", "discrete logarithm", "digital signature algorithm" }, .seeds = &.{"https://en.wikipedia.org/wiki/Elliptic-curve_cryptography"}, .trust = 0.8 },
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
    .{ .name = "apache-beam", .pack = packUrl("apache-beam"), .tags = &.{ "apache beam", "dataflow programming", "unified batch streaming", "data pipeline", "windowing semantics" }, .seeds = &.{"https://en.wikipedia.org/wiki/Apache_Beam"}, .trust = 0.8 },
    .{ .name = "apache-kafka-streams", .pack = packUrl("apache-kafka-streams"), .tags = &.{ "kafka streams", "stream processing library", "stateful stream processing", "event driven microservices", "apache kafka" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Kafka_Streams", "https://kafka.apache.org/documentation/streams/" }, .trust = 0.8 },
    .{ .name = "bert-model", .pack = packUrl("bert-model"), .tags = &.{ "bert model", "bidirectional transformer", "masked language model", "pretrained encoder" }, .seeds = &.{"https://en.wikipedia.org/wiki/BERT_(language_model)"}, .trust = 0.8 },
    .{ .name = "gpt-architecture", .pack = packUrl("gpt-architecture"), .tags = &.{ "gpt architecture", "generative pretrained transformer", "autoregressive language model", "decoder only model" }, .seeds = &.{"https://en.wikipedia.org/wiki/Generative_pre-trained_transformer"}, .trust = 0.8 },
    .{ .name = "vision-transformer", .pack = packUrl("vision-transformer"), .tags = &.{ "vision transformer", "image classification model", "patch embedding", "self attention vision" }, .seeds = &.{"https://en.wikipedia.org/wiki/Vision_transformer"}, .trust = 0.8 },
    .{ .name = "diffusion-models", .pack = packUrl("diffusion-models"), .tags = &.{ "diffusion model", "denoising diffusion", "score based model", "generative markov process" }, .seeds = &.{"https://en.wikipedia.org/wiki/Diffusion_model"}, .trust = 0.8 },
    .{ .name = "lora-peft", .pack = packUrl("lora-peft"), .tags = &.{ "low rank adaptation", "parameter efficient tuning", "adapter fine tuning", "rank decomposition" }, .seeds = &.{"https://en.wikipedia.org/wiki/Fine-tuning_(deep_learning)"}, .trust = 0.8 },
    .{ .name = "model-serving", .pack = packUrl("model-serving"), .tags = &.{ "model serving", "inference deployment", "request batching", "prediction endpoint" }, .seeds = &.{"https://en.wikipedia.org/wiki/Inference_engine"}, .trust = 0.8 },
    .{ .name = "model-context-protocol", .pack = packUrl("model-context-protocol"), .tags = &.{ "model context protocol", "tool calling standard", "json rpc interface", "llm interoperability" }, .seeds = &.{"https://en.wikipedia.org/wiki/Model_Context_Protocol"}, .trust = 0.8 },
    .{ .name = "gradient-boosting", .pack = packUrl("gradient-boosting"), .tags = &.{ "gradient boosting", "boosted decision trees", "additive model training", "xgboost library" }, .seeds = &.{"https://en.wikipedia.org/wiki/Gradient_boosting"}, .trust = 0.8 },
    .{ .name = "random-forest", .pack = packUrl("random-forest"), .tags = &.{ "random forest", "decision tree ensemble", "bootstrap aggregating", "feature bagging" }, .seeds = &.{"https://en.wikipedia.org/wiki/Random_forest"}, .trust = 0.8 },
    .{ .name = "support-vector-machine", .pack = packUrl("support-vector-machine"), .tags = &.{ "support vector machine", "maximum margin classifier", "kernel trick", "separating hyperplane" }, .seeds = &.{"https://en.wikipedia.org/wiki/Support_vector_machine"}, .trust = 0.8 },
    .{ .name = "principal-component-analysis", .pack = packUrl("principal-component-analysis"), .tags = &.{ "principal component analysis", "singular value decomposition", "eigenvalue decomposition", "variance projection" }, .seeds = &.{"https://en.wikipedia.org/wiki/Principal_component_analysis"}, .trust = 0.8 },
    .{ .name = "bayesian-inference", .pack = packUrl("bayesian-inference"), .tags = &.{ "bayesian inference", "posterior probability", "prior distribution", "probabilistic reasoning" }, .seeds = &.{"https://en.wikipedia.org/wiki/Bayesian_inference"}, .trust = 0.8 },
    .{ .name = "deep-reinforcement-learning", .pack = packUrl("deep-reinforcement-learning"), .tags = &.{ "deep reinforcement learning", "reward maximization", "policy learning", "agent environment loop" }, .seeds = &.{"https://en.wikipedia.org/wiki/Deep_reinforcement_learning"}, .trust = 0.8 },
    .{ .name = "unity-engine", .pack = packUrl("unity-engine"), .tags = &.{ "unity engine", "unity game engine", "unity3d", "unity component" }, .seeds = &.{"https://en.wikipedia.org/wiki/Unity_(game_engine)"}, .trust = 0.8 },
    .{ .name = "unreal-engine", .pack = packUrl("unreal-engine"), .tags = &.{ "unreal engine", "unreal game engine", "epic games engine", "unreal blueprint" }, .seeds = &.{"https://en.wikipedia.org/wiki/Unreal_Engine"}, .trust = 0.8 },
    .{ .name = "game-networking", .pack = packUrl("game-networking"), .tags = &.{ "game networking", "netcode", "multiplayer networking", "network game architecture" }, .seeds = &.{"https://en.wikipedia.org/wiki/Netcode"}, .trust = 0.8 },
    .{ .name = "behavior-trees", .pack = packUrl("behavior-trees"), .tags = &.{ "behavior tree", "behaviour tree ai", "game ai behavior", "behavior tree node" }, .seeds = &.{"https://en.wikipedia.org/wiki/Behavior_tree_(artificial_intelligence,_robotics_and_control)"}, .trust = 0.8 },
    .{ .name = "box2d-physics", .pack = packUrl("box2d-physics"), .tags = &.{ "box2d physics", "box2d engine", "2d physics library", "box2d body" }, .seeds = &.{"https://en.wikipedia.org/wiki/Box2D"}, .trust = 0.8 },
    .{ .name = "procedural-generation-games", .pack = packUrl("procedural-generation-games"), .tags = &.{ "procedural generation", "procedural content generation", "roguelike generation", "seeded generation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Procedural_generation"}, .trust = 0.8 },
    .{ .name = "directx-graphics", .pack = packUrl("directx-graphics"), .tags = &.{ "directx api", "direct3d", "hlsl shader", "directx raytracing" }, .seeds = &.{"https://en.wikipedia.org/wiki/DirectX"}, .trust = 0.8 },
    .{ .name = "metal-api", .pack = packUrl("metal-api"), .tags = &.{ "metal api", "apple metal", "metal shading language", "metal gpu" }, .seeds = &.{"https://en.wikipedia.org/wiki/Metal_(API)"}, .trust = 0.8 },
    .{ .name = "webgpu-api", .pack = packUrl("webgpu-api"), .tags = &.{ "webgpu api", "browser gpu", "gpu compute web", "webgpu device" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WebGPU", "https://developer.mozilla.org/en-US/docs/Web/API/WebGPU_API" }, .trust = 0.8 },
    .{ .name = "ray-tracing-rt", .pack = packUrl("ray-tracing-rt"), .tags = &.{ "ray tracing", "ray tracing hardware", "rtx gpu", "bvh acceleration" }, .seeds = &.{"https://en.wikipedia.org/wiki/Ray_tracing_(graphics)"}, .trust = 0.8 },
    .{ .name = "physically-based-rendering", .pack = packUrl("physically-based-rendering"), .tags = &.{ "physically based rendering", "pbr material", "microfacet model", "fresnel reflectance" }, .seeds = &.{"https://en.wikipedia.org/wiki/Physically_based_rendering"}, .trust = 0.8 },
    .{ .name = "ffmpeg", .pack = packUrl("ffmpeg"), .tags = &.{ "ffmpeg tool", "libavcodec", "video transcoding", "media conversion" }, .seeds = &.{"https://en.wikipedia.org/wiki/FFmpeg"}, .trust = 0.8 },
    .{ .name = "video-codec-h264", .pack = packUrl("video-codec-h264"), .tags = &.{ "h.264 codec", "advanced video coding", "cabac entropy", "motion compensation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Advanced_Video_Coding"}, .trust = 0.8 },
    .{ .name = "av1-codec", .pack = packUrl("av1-codec"), .tags = &.{ "av1 codec", "aomedia video", "royalty-free codec", "av1 encoding" }, .seeds = &.{"https://en.wikipedia.org/wiki/AV1"}, .trust = 0.8 },
    .{ .name = "gltf-format", .pack = packUrl("gltf-format"), .tags = &.{ "gltf format", "khronos gltf", "3d asset transmission", "pbr gltf" }, .seeds = &.{"https://en.wikipedia.org/wiki/GlTF"}, .trust = 0.8 },
    .{ .name = "opus-codec", .pack = packUrl("opus-codec"), .tags = &.{ "opus audio", "celt codec", "silk speech", "voip audio codec" }, .seeds = &.{"https://en.wikipedia.org/wiki/Opus_(audio_format)"}, .trust = 0.8 },
    .{ .name = "json-schema", .pack = packUrl("json-schema"), .tags = &.{ "json schema", "schema validation", "json validation", "data contract" }, .seeds = &.{ "https://en.wikipedia.org/wiki/JSON", "https://json-schema.org/understanding-json-schema/" }, .trust = 0.8 },
    .{ .name = "apache-avro", .pack = packUrl("apache-avro"), .tags = &.{ "apache avro", "row oriented serialization", "schema registry", "compact binary format", "remote procedure call" }, .seeds = &.{"https://en.wikipedia.org/wiki/Apache_Avro"}, .trust = 0.8 },
    .{ .name = "openid-connect", .pack = packUrl("openid-connect"), .tags = &.{ "openid connect", "oidc protocol", "id token authentication", "oauth identity layer" }, .seeds = &.{"https://en.wikipedia.org/wiki/OpenID_Connect"}, .trust = 0.8 },
    .{ .name = "saml-federation", .pack = packUrl("saml-federation"), .tags = &.{ "saml federation", "security assertion markup language", "saml assertion", "browser sso federation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Security_Assertion_Markup_Language"}, .trust = 0.8 },
    .{ .name = "server-sent-events", .pack = packUrl("server-sent-events"), .tags = &.{ "server-sent events", "sse streaming", "eventsource api", "http push stream" }, .seeds = &.{"https://en.wikipedia.org/wiki/Server-sent_events"}, .trust = 0.8 },
    .{ .name = "sparql-query", .pack = packUrl("sparql-query"), .tags = &.{ "sparql query language", "rdf query language", "semantic web query", "triple pattern query" }, .seeds = &.{"https://en.wikipedia.org/wiki/SPARQL"}, .trust = 0.8 },
    .{ .name = "cypher-query", .pack = packUrl("cypher-query"), .tags = &.{ "cypher query language", "neo4j cypher", "graph pattern query", "property graph query" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cypher_(query_language)"}, .trust = 0.8 },
    .{ .name = "promql", .pack = packUrl("promql"), .tags = &.{ "promql query", "prometheus query language", "time-series query", "metrics query language" }, .seeds = &.{"https://en.wikipedia.org/wiki/Prometheus_(software)"}, .trust = 0.8 },
    .{ .name = "protocol-buffers-idl", .pack = packUrl("protocol-buffers-idl"), .tags = &.{ "protocol buffers", "protobuf idl", "interface description language", "binary serialization schema" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Protocol_Buffers", "https://protobuf.dev/" }, .trust = 0.8 },
    .{ .name = "yara-rules", .pack = packUrl("yara-rules"), .tags = &.{ "yara rules", "malware signature", "pattern matching detection", "antivirus engine", "signature based detection" }, .seeds = &.{"https://en.wikipedia.org/wiki/YARA"}, .trust = 0.8 },
    .{ .name = "sigma-detection-rules", .pack = packUrl("sigma-detection-rules"), .tags = &.{ "sigma detection rules", "log detection format", "detection engineering", "rule based system", "security event correlation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Rule-based_system"}, .trust = 0.8 },
    .{ .name = "suricata-ids", .pack = packUrl("suricata-ids"), .tags = &.{ "suricata ids", "network intrusion detection", "deep packet inspection", "intrusion prevention system", "packet capture analysis" }, .seeds = &.{"https://en.wikipedia.org/wiki/Suricata_(software)"}, .trust = 0.8 },
    .{ .name = "threat-hunting", .pack = packUrl("threat-hunting"), .tags = &.{ "cyber threat hunting", "proactive threat detection", "indicator of compromise", "advanced persistent threat", "hypothesis driven investigation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cyber_threat_hunting"}, .trust = 0.8 },
    .{ .name = "post-quantum-cryptography", .pack = packUrl("post-quantum-cryptography"), .tags = &.{ "post quantum cryptography", "quantum resistant algorithm", "shor algorithm threat", "nist pqc standardization", "quantum safe encryption" }, .seeds = &.{"https://en.wikipedia.org/wiki/Post-quantum_cryptography"}, .trust = 0.8 },
    .{ .name = "memory-forensics-volatility", .pack = packUrl("memory-forensics-volatility"), .tags = &.{ "memory forensics volatility", "volatile memory acquisition", "process memory dump analysis", "core dump inspection", "digital evidence recovery" }, .seeds = &.{"https://en.wikipedia.org/wiki/Memory_forensics"}, .trust = 0.8 },
    .{ .name = "reverse-engineering-ghidra", .pack = packUrl("reverse-engineering-ghidra"), .tags = &.{ "ghidra reverse engineering", "software reverse engineering", "binary decompiler analysis", "disassembly workflow", "malware code analysis" }, .seeds = &.{"https://en.wikipedia.org/wiki/Ghidra"}, .trust = 0.8 },
    .{ .name = "confidential-computing", .pack = packUrl("confidential-computing"), .tags = &.{ "confidential computing", "data in use protection", "trusted execution environment", "encrypted memory enclave", "hardware attestation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Confidential_computing"}, .trust = 0.8 },
    .{ .name = "win32-api", .pack = packUrl("win32-api"), .tags = &.{ "win32 api", "windows api", "windows programming", "dynamic-link library" }, .seeds = &.{"https://en.wikipedia.org/wiki/Windows_API"}, .trust = 0.8 },
    .{ .name = "cocoa-framework", .pack = packUrl("cocoa-framework"), .tags = &.{ "cocoa framework", "cocoa api", "objective-c runtime", "interface builder" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cocoa_(API)"}, .trust = 0.8 },
    .{ .name = "jetpack-compose", .pack = packUrl("jetpack-compose"), .tags = &.{ "jetpack compose", "declarative ui", "kotlin language", "android development" }, .seeds = &.{"https://en.wikipedia.org/wiki/Jetpack_Compose"}, .trust = 0.8 },
    .{ .name = "swiftui-framework", .pack = packUrl("swiftui-framework"), .tags = &.{ "swiftui framework", "swift language", "declarative ui", "data binding" }, .seeds = &.{"https://en.wikipedia.org/wiki/SwiftUI"}, .trust = 0.8 },
    .{ .name = "debian-linux", .pack = packUrl("debian-linux"), .tags = &.{ "debian linux", "apt package manager", "dpkg tool", "debian release" }, .seeds = &.{"https://en.wikipedia.org/wiki/Debian"}, .trust = 0.8 },
    .{ .name = "wayland-protocol", .pack = packUrl("wayland-protocol"), .tags = &.{ "wayland protocol", "wayland compositor", "weston reference", "display server" }, .seeds = &.{"https://en.wikipedia.org/wiki/Wayland_(protocol)"}, .trust = 0.8 },
    .{ .name = "wasm-toolchain", .pack = packUrl("wasm-toolchain"), .tags = &.{ "webassembly toolchain", "wasm bytecode", "wasm stack machine", "wasm binary format" }, .seeds = &.{ "https://en.wikipedia.org/wiki/WebAssembly", "https://webassembly.org/" }, .trust = 0.8 },
    .{ .name = "systemverilog", .pack = packUrl("systemverilog"), .tags = &.{ "systemverilog language", "hardware verification language", "rtl verification", "hardware description language" }, .seeds = &.{"https://en.wikipedia.org/wiki/SystemVerilog"}, .trust = 0.8 },
    .{ .name = "uvm-verification", .pack = packUrl("uvm-verification"), .tags = &.{ "uvm methodology", "universal verification methodology", "functional verification", "constrained random testing" }, .seeds = &.{"https://en.wikipedia.org/wiki/Universal_Verification_Methodology"}, .trust = 0.8 },
    .{ .name = "rtl-synthesis", .pack = packUrl("rtl-synthesis"), .tags = &.{ "rtl synthesis", "logic synthesis", "technology mapping", "gate netlist" }, .seeds = &.{"https://en.wikipedia.org/wiki/Logic_synthesis"}, .trust = 0.8 },
    .{ .name = "spice-simulation", .pack = packUrl("spice-simulation"), .tags = &.{ "spice simulation", "circuit simulation", "netlist analysis", "transistor modeling" }, .seeds = &.{"https://en.wikipedia.org/wiki/SPICE"}, .trust = 0.8 },
    .{ .name = "cpu-microarchitecture", .pack = packUrl("cpu-microarchitecture"), .tags = &.{ "cpu microarchitecture", "instruction pipelining", "risc pipeline stages", "processor datapath" }, .seeds = &.{"https://en.wikipedia.org/wiki/Microarchitecture"}, .trust = 0.8 },
    .{ .name = "gpu-microarchitecture", .pack = packUrl("gpu-microarchitecture"), .tags = &.{ "gpu microarchitecture", "stream processing", "single instruction multiple threads", "shader cores" }, .seeds = &.{"https://en.wikipedia.org/wiki/Graphics_processing_unit"}, .trust = 0.8 },
    .{ .name = "fhir-health", .pack = packUrl("fhir-health"), .tags = &.{ "fhir standard", "health interoperability", "hl7 fhir", "electronic health record" }, .seeds = &.{"https://en.wikipedia.org/wiki/Fast_Healthcare_Interoperability_Resources"}, .trust = 0.8 },
    .{ .name = "dicom-imaging", .pack = packUrl("dicom-imaging"), .tags = &.{ "dicom imaging", "medical imaging", "picture archiving", "radiology information" }, .seeds = &.{"https://en.wikipedia.org/wiki/DICOM"}, .trust = 0.8 },
    .{ .name = "quantitative-finance", .pack = packUrl("quantitative-finance"), .tags = &.{ "quantitative finance", "mathematical finance", "financial modeling", "derivatives pricing" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantitative_analysis_(finance)"}, .trust = 0.8 },
    .{ .name = "geospatial-gis", .pack = packUrl("geospatial-gis"), .tags = &.{ "geospatial gis", "spatial analysis", "geographic information", "digital cartography" }, .seeds = &.{"https://en.wikipedia.org/wiki/Geographic_information_system"}, .trust = 0.8 },
    .{ .name = "postgis", .pack = packUrl("postgis"), .tags = &.{ "postgis spatial", "spatial database", "geometry storage", "well known text" }, .seeds = &.{ "https://en.wikipedia.org/wiki/PostGIS", "https://postgis.net/documentation/" }, .trust = 0.8 },
    .{ .name = "wordpress-cms", .pack = packUrl("wordpress-cms"), .tags = &.{ "wordpress cms", "content management system", "wordpress plugin", "wordpress theme" }, .seeds = &.{"https://en.wikipedia.org/wiki/WordPress"}, .trust = 0.8 },
    .{ .name = "telecom-5g", .pack = packUrl("telecom-5g"), .tags = &.{ "5g network", "5g new radio", "network slicing", "millimeter wave 5g" }, .seeds = &.{"https://en.wikipedia.org/wiki/5G"}, .trust = 0.8 },
    .{ .name = "automotive-autosar", .pack = packUrl("automotive-autosar"), .tags = &.{ "autosar architecture", "automotive software", "electronic control unit", "automotive rtos" }, .seeds = &.{"https://en.wikipedia.org/wiki/AUTOSAR"}, .trust = 0.8 },
    .{ .name = "digital-twin", .pack = packUrl("digital-twin"), .tags = &.{ "digital twin", "cyber physical system", "simulation model", "predictive maintenance twin" }, .seeds = &.{"https://en.wikipedia.org/wiki/Digital_twin"}, .trust = 0.8 },
    .{ .name = "scipy-library", .pack = packUrl("scipy-library"), .tags = &.{ "scipy library", "scientific python", "numerical routines", "signal processing scipy" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SciPy", "https://docs.scipy.org/doc/scipy/tutorial/index.html" }, .trust = 0.8 },
    .{ .name = "sympy-symbolic", .pack = packUrl("sympy-symbolic"), .tags = &.{ "sympy symbolic", "computer algebra", "symbolic integration", "equation solving" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SymPy", "https://docs.sympy.org/latest/tutorials/intro-tutorial/index.html" }, .trust = 0.8 },
    .{ .name = "quantum-chemistry-dft", .pack = packUrl("quantum-chemistry-dft"), .tags = &.{ "quantum chemistry", "electronic structure", "coupled cluster", "configuration interaction" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantum_chemistry"}, .trust = 0.8 },
    .{ .name = "high-performance-computing", .pack = packUrl("high-performance-computing"), .tags = &.{ "high-performance computing", "parallel computing", "amdahl law", "gpu general-purpose computing" }, .seeds = &.{"https://en.wikipedia.org/wiki/High-performance_computing"}, .trust = 0.8 },
    .{ .name = "mpi-parallel-computing", .pack = packUrl("mpi-parallel-computing"), .tags = &.{ "message passing interface", "distributed memory parallelism", "process communication mpi", "collective communication" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Message_Passing_Interface", "https://mpi4py.readthedocs.io/en/stable/" }, .trust = 0.8 },
    .{ .name = "agent-based-modeling", .pack = packUrl("agent-based-modeling"), .tags = &.{ "agent-based model", "complex adaptive system", "swarm intelligence", "segregation model" }, .seeds = &.{"https://en.wikipedia.org/wiki/Agent-based_model"}, .trust = 0.8 },
    .{ .name = "content-security-policy", .pack = packUrl("content-security-policy"), .tags = &.{ "content security policy", "csp header", "xss mitigation", "script-src directive", "default-src fallback" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Content_Security_Policy", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP" }, .trust = 0.8 },
    .{ .name = "cross-origin-resource-sharing", .pack = packUrl("cross-origin-resource-sharing"), .tags = &.{ "cross-origin resource sharing", "cors preflight request", "access-control-allow-origin header", "credentialed cross-origin request" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cross-origin_resource_sharing", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS" }, .trust = 0.8 },
    .{ .name = "core-web-vitals", .pack = packUrl("core-web-vitals"), .tags = &.{ "core web vitals", "largest contentful paint", "cumulative layout shift", "performance observer entry" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Web_performance", "https://developer.mozilla.org/en-US/docs/Web/API/Largest_Contentful_Paint_API" }, .trust = 0.8 },
    .{ .name = "server-side-rendering-web", .pack = packUrl("server-side-rendering-web"), .tags = &.{ "server side rendering", "client side hydration", "dynamic web page", "server-side scripting" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Server-side_scripting", "https://developer.mozilla.org/en-US/docs/Glossary/SSR" }, .trust = 0.8 },
    .{ .name = "micro-frontends", .pack = packUrl("micro-frontends"), .tags = &.{ "micro frontends", "frontend composition", "separation of concerns", "iframe isolation boundary" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Micro_frontend", "https://developer.mozilla.org/en-US/docs/Web/API/Web_components" }, .trust = 0.8 },
    .{ .name = "search-engine-optimization", .pack = packUrl("search-engine-optimization"), .tags = &.{ "search engine optimization", "meta description tag", "canonical link relation", "web crawler indexing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Search_engine_optimization", "https://developer.mozilla.org/en-US/docs/Glossary/SEO" }, .trust = 0.8 },
    .{ .name = "language-server-protocol", .pack = packUrl("language-server-protocol"), .tags = &.{ "language server protocol", "lsp editor tooling", "code intelligence protocol", "json-rpc editor" }, .seeds = &.{"https://en.wikipedia.org/wiki/Language_Server_Protocol"}, .trust = 0.8 },
    .{ .name = "tree-sitter-parsing", .pack = packUrl("tree-sitter-parsing"), .tags = &.{ "tree-sitter parser", "incremental parsing", "concrete syntax tree", "editor syntax parsing" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Tree-sitter_(parser_generator)", "https://tree-sitter.github.io/tree-sitter/" }, .trust = 0.8 },
    .{ .name = "llvm-infrastructure", .pack = packUrl("llvm-infrastructure"), .tags = &.{ "llvm infrastructure", "llvm compiler toolchain", "optimizing compiler backend", "clang frontend" }, .seeds = &.{ "https://en.wikipedia.org/wiki/LLVM", "https://llvm.org/docs/LangRef.html" }, .trust = 0.8 },
    .{ .name = "rego-opa-policy", .pack = packUrl("rego-opa-policy"), .tags = &.{ "rego policy", "open policy agent", "policy as code", "rego datalog rules" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Datalog", "https://www.openpolicyagent.org/docs/latest/policy-language/" }, .trust = 0.8 },
    .{ .name = "turborepo", .pack = packUrl("turborepo"), .tags = &.{ "turborepo monorepo", "turbo build cache", "monorepo task pipeline", "incremental build cache" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Monorepo", "https://turbo.build/repo/docs" }, .trust = 0.8 },
    .{ .name = "jsonnet", .pack = packUrl("jsonnet"), .tags = &.{ "jsonnet language", "data templating language", "json config generation", "google jsonnet" }, .seeds = &.{ "https://en.wikipedia.org/wiki/JSON", "https://jsonnet.org/" }, .trust = 0.8 },
    // — mega-pack wave 5: named-algorithm/data-structure catalogs, per-language library
    // ecosystems (python/js/rust/go/java/cpp), and the deep science tail (advanced math,
    // physics, electrical/RF, chemistry, biology/medical, deep networking, deep appsec).
    // Registry tags, bare-word filtered; trust 0.8. —
    .{ .name = "dijkstra-shortest-path", .pack = packUrl("dijkstra-shortest-path"), .tags = &.{ "dijkstra algorithm", "shortest path", "graph traversal", "priority queue" }, .seeds = &.{"https://en.wikipedia.org/wiki/Dijkstra's_algorithm"}, .trust = 0.8 },
    .{ .name = "a-star-search", .pack = packUrl("a-star-search"), .tags = &.{ "a star search", "admissible heuristic", "pathfinding algorithm", "best first search" }, .seeds = &.{"https://en.wikipedia.org/wiki/A*_search_algorithm"}, .trust = 0.8 },
    .{ .name = "quicksort-algorithm", .pack = packUrl("quicksort-algorithm"), .tags = &.{ "quicksort algorithm", "divide and conquer", "partition scheme", "quickselect algorithm" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quicksort"}, .trust = 0.8 },
    .{ .name = "kmp-string-matching", .pack = packUrl("kmp-string-matching"), .tags = &.{ "knuth morris pratt", "string searching algorithm", "prefix function", "pattern matching" }, .seeds = &.{"https://en.wikipedia.org/wiki/Knuth–Morris–Pratt_algorithm"}, .trust = 0.8 },
    .{ .name = "fft-algorithm", .pack = packUrl("fft-algorithm"), .tags = &.{ "fast fourier transform", "cooley tukey algorithm", "discrete fourier transform", "convolution theorem" }, .seeds = &.{"https://en.wikipedia.org/wiki/Fast_Fourier_transform"}, .trust = 0.8 },
    .{ .name = "dynamic-programming-foundations", .pack = packUrl("dynamic-programming-foundations"), .tags = &.{ "dynamic programming", "memoization technique", "optimal substructure", "bellman equation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Dynamic_programming"}, .trust = 0.8 },
    .{ .name = "union-find-algorithm", .pack = packUrl("union-find-algorithm"), .tags = &.{ "disjoint set data structure", "union by rank", "amortized analysis", "connected components" }, .seeds = &.{"https://en.wikipedia.org/wiki/Disjoint-set_data_structure"}, .trust = 0.8 },
    .{ .name = "pagerank-algorithm", .pack = packUrl("pagerank-algorithm"), .tags = &.{ "pagerank algorithm", "link analysis", "power iteration", "markov chain" }, .seeds = &.{"https://en.wikipedia.org/wiki/PageRank"}, .trust = 0.8 },
    .{ .name = "viterbi-algorithm", .pack = packUrl("viterbi-algorithm"), .tags = &.{ "viterbi algorithm", "hidden markov model", "dynamic programming", "forward algorithm" }, .seeds = &.{"https://en.wikipedia.org/wiki/Viterbi_algorithm"}, .trust = 0.8 },
    .{ .name = "red-black-tree", .pack = packUrl("red-black-tree"), .tags = &.{ "red-black tree", "balanced binary tree", "self-balancing tree", "left-leaning red-black tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/Red–black_tree"}, .trust = 0.8 },
    .{ .name = "b-tree-structure", .pack = packUrl("b-tree-structure"), .tags = &.{ "b-tree", "multiway search tree", "disk-based index", "database index tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/B-tree"}, .trust = 0.8 },
    .{ .name = "hash-table-structure", .pack = packUrl("hash-table-structure"), .tags = &.{ "hash table", "hash function", "hash collision", "separate chaining" }, .seeds = &.{"https://en.wikipedia.org/wiki/Hash_table"}, .trust = 0.8 },
    .{ .name = "trie-structure", .pack = packUrl("trie-structure"), .tags = &.{ "prefix trie", "digital tree", "ternary search tree", "radix tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/Trie"}, .trust = 0.8 },
    .{ .name = "segment-tree", .pack = packUrl("segment-tree"), .tags = &.{ "segment tree", "range query structure", "interval tree", "range minimum query" }, .seeds = &.{"https://en.wikipedia.org/wiki/Segment_tree"}, .trust = 0.8 },
    .{ .name = "fenwick-tree", .pack = packUrl("fenwick-tree"), .tags = &.{ "fenwick tree", "binary indexed tree", "prefix sum structure", "cumulative frequency table" }, .seeds = &.{"https://en.wikipedia.org/wiki/Fenwick_tree"}, .trust = 0.8 },
    .{ .name = "skip-list", .pack = packUrl("skip-list"), .tags = &.{ "skip list", "probabilistic list", "ordered list structure", "skip graph" }, .seeds = &.{"https://en.wikipedia.org/wiki/Skip_list"}, .trust = 0.8 },
    .{ .name = "bloom-filter-structure", .pack = packUrl("bloom-filter-structure"), .tags = &.{ "bloom filter", "probabilistic set", "approximate membership", "false positive rate" }, .seeds = &.{"https://en.wikipedia.org/wiki/Bloom_filter"}, .trust = 0.8 },
    .{ .name = "kd-tree", .pack = packUrl("kd-tree"), .tags = &.{ "k-d tree", "space partitioning tree", "nearest neighbor search", "implicit k-d tree" }, .seeds = &.{"https://en.wikipedia.org/wiki/K-d_tree"}, .trust = 0.8 },
    .{ .name = "disjoint-set-forest", .pack = packUrl("disjoint-set-forest"), .tags = &.{ "disjoint-set data structure", "union-find forest", "connected components structure", "path compression" }, .seeds = &.{"https://en.wikipedia.org/wiki/Disjoint-set_data_structure"}, .trust = 0.8 },
    .{ .name = "requests-http", .pack = packUrl("requests-http"), .tags = &.{ "python requests", "http client python", "requests library" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Requests_(software)", "https://requests.readthedocs.io/en/latest/user/quickstart/" }, .trust = 0.8 },
    .{ .name = "pydantic-validation", .pack = packUrl("pydantic-validation"), .tags = &.{ "python pydantic", "data validation library", "pydantic models" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Data_validation", "https://docs.pydantic.dev/latest/concepts/models/" }, .trust = 0.8 },
    .{ .name = "celery-tasks", .pack = packUrl("celery-tasks"), .tags = &.{ "python celery", "celery task queue", "distributed task python" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Celery_(software)", "https://docs.celeryq.dev/en/stable/getting-started/introduction.html" }, .trust = 0.8 },
    .{ .name = "sqlalchemy-core", .pack = packUrl("sqlalchemy-core"), .tags = &.{ "python sqlalchemy", "sqlalchemy orm", "database toolkit python" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SQLAlchemy", "https://docs.sqlalchemy.org/en/20/tutorial/index.html" }, .trust = 0.8 },
    .{ .name = "pandas-dataframe", .pack = packUrl("pandas-dataframe"), .tags = &.{ "python pandas", "pandas dataframe", "data analysis python" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Pandas_(software)", "https://pandas.pydata.org/docs/user_guide/10min.html" }, .trust = 0.8 },
    .{ .name = "numpy-arrays", .pack = packUrl("numpy-arrays"), .tags = &.{ "python numpy", "numpy arrays", "numerical computing python" }, .seeds = &.{ "https://en.wikipedia.org/wiki/NumPy", "https://numpy.org/doc/stable/user/absolute_beginners.html" }, .trust = 0.8 },
    .{ .name = "asyncio-python", .pack = packUrl("asyncio-python"), .tags = &.{ "python asyncio", "asyncio event loop", "async await python" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Async/await", "https://docs.python.org/3/library/asyncio.html" }, .trust = 0.8 },
    .{ .name = "axios-http", .pack = packUrl("axios-http"), .tags = &.{ "axios http", "promise http client", "javascript ajax", "request interceptor" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ajax_(programming)", "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise" }, .trust = 0.8 },
    .{ .name = "rxjs-observable", .pack = packUrl("rxjs-observable"), .tags = &.{ "rxjs observable", "reactive extensions", "observable stream", "async event pipeline" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Reactive_programming", "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Iterators_and_generators" }, .trust = 0.8 },
    .{ .name = "zod-schema", .pack = packUrl("zod-schema"), .tags = &.{ "zod schema", "typescript validation", "schema inference", "runtime type checking" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Data_validation", "https://developer.mozilla.org/en-US/docs/Glossary/Type_conversion" }, .trust = 0.8 },
    .{ .name = "mongoose-odm", .pack = packUrl("mongoose-odm"), .tags = &.{ "mongoose odm", "mongodb object modeling", "schema-based document model", "odm population query" }, .seeds = &.{ "https://en.wikipedia.org/wiki/MongoDB", "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/JSON" }, .trust = 0.8 },
    .{ .name = "tokio-async-rust", .pack = packUrl("tokio-async-rust"), .tags = &.{ "tokio runtime", "rust async runtime", "async i/o rust", "tokio tasks" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Rust_(programming_language)", "https://docs.rs/tokio/latest/tokio/" }, .trust = 0.8 },
    .{ .name = "serde-rust", .pack = packUrl("serde-rust"), .tags = &.{ "serde serialization", "rust serde", "serde deserialize", "rust data format" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Rust_(programming_language)", "https://docs.rs/serde/latest/serde/" }, .trust = 0.8 },
    .{ .name = "algebraic-topology", .pack = packUrl("algebraic-topology"), .tags = &.{ "algebraic topology", "homotopy theory", "homology group", "fundamental group" }, .seeds = &.{"https://en.wikipedia.org/wiki/Algebraic_topology"}, .trust = 0.8 },
    .{ .name = "representation-theory", .pack = packUrl("representation-theory"), .tags = &.{ "representation theory", "group representation", "character theory", "irreducible representation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Representation_theory"}, .trust = 0.8 },
    .{ .name = "algebraic-geometry", .pack = packUrl("algebraic-geometry"), .tags = &.{ "algebraic geometry", "algebraic variety", "zariski topology", "scheme theory" }, .seeds = &.{"https://en.wikipedia.org/wiki/Algebraic_geometry"}, .trust = 0.8 },
    .{ .name = "lie-groups", .pack = packUrl("lie-groups"), .tags = &.{ "lie group", "lie theory", "compact group", "maximal torus" }, .seeds = &.{"https://en.wikipedia.org/wiki/Lie_group"}, .trust = 0.8 },
    .{ .name = "galois-theory", .pack = packUrl("galois-theory"), .tags = &.{ "galois theory", "galois group", "field extension", "solvable group" }, .seeds = &.{"https://en.wikipedia.org/wiki/Galois_theory"}, .trust = 0.8 },
    .{ .name = "stochastic-calculus", .pack = packUrl("stochastic-calculus"), .tags = &.{ "stochastic calculus", "stochastic differential equation", "wiener process", "feynman-kac formula" }, .seeds = &.{"https://en.wikipedia.org/wiki/Stochastic_calculus"}, .trust = 0.8 },
    .{ .name = "knot-theory", .pack = packUrl("knot-theory"), .tags = &.{ "knot theory", "knot invariant", "jones polynomial", "braid group" }, .seeds = &.{"https://en.wikipedia.org/wiki/Knot_theory"}, .trust = 0.8 },
    .{ .name = "quantum-mechanics", .pack = packUrl("quantum-mechanics"), .tags = &.{ "quantum mechanics", "schrodinger equation", "wave function", "uncertainty principle" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantum_mechanics"}, .trust = 0.8 },
    .{ .name = "quantum-field-theory", .pack = packUrl("quantum-field-theory"), .tags = &.{ "quantum field theory", "gauge theory", "feynman diagram", "path integral formulation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantum_field_theory"}, .trust = 0.8 },
    .{ .name = "special-relativity", .pack = packUrl("special-relativity"), .tags = &.{ "special relativity", "lorentz transformation", "time dilation", "mass-energy equivalence" }, .seeds = &.{"https://en.wikipedia.org/wiki/Special_relativity"}, .trust = 0.8 },
    .{ .name = "general-relativity", .pack = packUrl("general-relativity"), .tags = &.{ "general relativity", "einstein field equations", "spacetime curvature", "gravitational wave" }, .seeds = &.{"https://en.wikipedia.org/wiki/General_relativity"}, .trust = 0.8 },
    .{ .name = "electromagnetism", .pack = packUrl("electromagnetism"), .tags = &.{ "classical electromagnetism", "electromagnetic field", "lorentz force", "electromagnetic induction" }, .seeds = &.{"https://en.wikipedia.org/wiki/Electromagnetism"}, .trust = 0.8 },
    .{ .name = "thermodynamics", .pack = packUrl("thermodynamics"), .tags = &.{ "laws of thermodynamics", "thermodynamic entropy", "free energy", "first law of thermodynamics" }, .seeds = &.{"https://en.wikipedia.org/wiki/Thermodynamics"}, .trust = 0.8 },
    .{ .name = "condensed-matter-physics", .pack = packUrl("condensed-matter-physics"), .tags = &.{ "condensed matter physics", "crystal structure", "electronic band structure", "fermi surface" }, .seeds = &.{"https://en.wikipedia.org/wiki/Condensed_matter_physics"}, .trust = 0.8 },
    .{ .name = "transmission-lines", .pack = packUrl("transmission-lines"), .tags = &.{ "transmission line", "characteristic impedance", "standing wave ratio", "reflection coefficient" }, .seeds = &.{"https://en.wikipedia.org/wiki/Transmission_line"}, .trust = 0.8 },
    .{ .name = "antenna-theory", .pack = packUrl("antenna-theory"), .tags = &.{ "dipole antenna", "radiation pattern", "antenna aperture", "monopole antenna" }, .seeds = &.{"https://en.wikipedia.org/wiki/Antenna_(radio)"}, .trust = 0.8 },
    .{ .name = "operational-amplifiers", .pack = packUrl("operational-amplifiers"), .tags = &.{ "operational amplifier", "op amp integrator", "differential amplifier", "chopper amplifier" }, .seeds = &.{"https://en.wikipedia.org/wiki/Operational_amplifier"}, .trust = 0.8 },
    .{ .name = "phase-locked-loop", .pack = packUrl("phase-locked-loop"), .tags = &.{ "phase-locked loop", "charge pump", "phase detector", "loop gain" }, .seeds = &.{"https://en.wikipedia.org/wiki/Phase-locked_loop"}, .trust = 0.8 },
    .{ .name = "buck-converter", .pack = packUrl("buck-converter"), .tags = &.{ "buck converter", "boost converter", "buck-boost converter", "cuk converter" }, .seeds = &.{"https://en.wikipedia.org/wiki/Buck_converter"}, .trust = 0.8 },
    .{ .name = "field-oriented-control", .pack = packUrl("field-oriented-control"), .tags = &.{ "vector control motor", "clarke transformation", "space vector modulation", "field-oriented control" }, .seeds = &.{"https://en.wikipedia.org/wiki/Vector_control_(motor)"}, .trust = 0.8 },
    .{ .name = "organic-chemistry", .pack = packUrl("organic-chemistry"), .tags = &.{ "organic chemistry", "functional groups", "reaction mechanisms", "aromatic compounds" }, .seeds = &.{"https://en.wikipedia.org/wiki/Organic_chemistry"}, .trust = 0.8 },
    .{ .name = "electrochemistry", .pack = packUrl("electrochemistry"), .tags = &.{ "electrochemistry cells", "galvanic cell", "electrode potential", "cell potential" }, .seeds = &.{"https://en.wikipedia.org/wiki/Electrochemistry"}, .trust = 0.8 },
    .{ .name = "crystallography", .pack = packUrl("crystallography"), .tags = &.{ "crystallography lattices", "crystal system", "bravais lattice", "space group" }, .seeds = &.{"https://en.wikipedia.org/wiki/Crystallography"}, .trust = 0.8 },
    .{ .name = "polymer-chemistry", .pack = packUrl("polymer-chemistry"), .tags = &.{ "polymer chemistry", "glass transition", "cross linking", "molar mass distribution" }, .seeds = &.{"https://en.wikipedia.org/wiki/Polymer_chemistry"}, .trust = 0.8 },
    .{ .name = "materials-science", .pack = packUrl("materials-science"), .tags = &.{ "materials science", "crystallographic defect", "grain boundary", "mechanical properties" }, .seeds = &.{"https://en.wikipedia.org/wiki/Materials_science"}, .trust = 0.8 },
    .{ .name = "molecular-biology", .pack = packUrl("molecular-biology"), .tags = &.{ "molecular biology", "dna replication", "gene expression", "central dogma" }, .seeds = &.{"https://en.wikipedia.org/wiki/Molecular_biology"}, .trust = 0.8 },
    .{ .name = "genomics-biology", .pack = packUrl("genomics-biology"), .tags = &.{ "genome organization", "human genome", "genome annotation", "noncoding dna" }, .seeds = &.{"https://en.wikipedia.org/wiki/Genome"}, .trust = 0.8 },
    .{ .name = "crispr-gene-editing", .pack = packUrl("crispr-gene-editing"), .tags = &.{ "crispr gene editing", "cas9 nuclease", "guide rna", "genome editing" }, .seeds = &.{"https://en.wikipedia.org/wiki/CRISPR"}, .trust = 0.8 },
    .{ .name = "immunology", .pack = packUrl("immunology"), .tags = &.{ "immune system", "innate immunity", "immune response", "inflammation biology" }, .seeds = &.{"https://en.wikipedia.org/wiki/Immunology"}, .trust = 0.8 },
    .{ .name = "neuroscience-fundamentals", .pack = packUrl("neuroscience-fundamentals"), .tags = &.{ "neuroscience fundamentals", "nervous system", "central nervous system", "glial cell" }, .seeds = &.{"https://en.wikipedia.org/wiki/Neuroscience"}, .trust = 0.8 },
    .{ .name = "pharmacology", .pack = packUrl("pharmacology"), .tags = &.{ "pharmacology principles", "drug receptor", "dose response", "receptor agonist" }, .seeds = &.{"https://en.wikipedia.org/wiki/Pharmacology"}, .trust = 0.8 },
    .{ .name = "vxlan-overlay", .pack = packUrl("vxlan-overlay"), .tags = &.{ "vxlan overlay", "network overlay", "layer 2 tunneling", "network virtualization" }, .seeds = &.{"https://en.wikipedia.org/wiki/Virtual_Extensible_LAN"}, .trust = 0.8 },
    .{ .name = "segment-routing", .pack = packUrl("segment-routing"), .tags = &.{ "segment routing", "source routing", "srv6 dataplane", "traffic steering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Segment_routing"}, .trust = 0.8 },
    .{ .name = "rdma-networking", .pack = packUrl("rdma-networking"), .tags = &.{ "remote direct memory access", "zero-copy transfer", "kernel bypass", "low latency networking" }, .seeds = &.{"https://en.wikipedia.org/wiki/Remote_direct_memory_access"}, .trust = 0.8 },
    .{ .name = "cellular-5g-nr", .pack = packUrl("cellular-5g-nr"), .tags = &.{ "5g new radio", "5g networking", "millimeter wave", "massive mimo" }, .seeds = &.{"https://en.wikipedia.org/wiki/5G_NR"}, .trust = 0.8 },
    .{ .name = "optical-networking", .pack = packUrl("optical-networking"), .tags = &.{ "optical networking", "optical communication", "optical transport", "optical amplifier" }, .seeds = &.{"https://en.wikipedia.org/wiki/Optical_communication"}, .trust = 0.8 },
    .{ .name = "ssrf-defense", .pack = packUrl("ssrf-defense"), .tags = &.{ "server-side request forgery", "ssrf mitigation", "url validation defense", "outbound request filtering" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Server-side_request_forgery", "https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html" }, .trust = 0.8 },
    .{ .name = "insecure-deserialization", .pack = packUrl("insecure-deserialization"), .tags = &.{ "insecure deserialization", "object serialization risk", "deserialization gadget chain", "untrusted data marshalling" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Serialization", "https://cheatsheetseries.owasp.org/cheatsheets/Deserialization_Cheat_Sheet.html" }, .trust = 0.8 },
    .{ .name = "oauth-security-hardening", .pack = packUrl("oauth-security-hardening"), .tags = &.{ "oauth security hardening", "authorization code flow", "pkce proof key", "token leakage defense" }, .seeds = &.{ "https://en.wikipedia.org/wiki/OAuth", "https://oauth.net/2/" }, .trust = 0.8 },
    .{ .name = "tls-configuration-hardening", .pack = packUrl("tls-configuration-hardening"), .tags = &.{ "tls configuration hardening", "cipher suite selection", "perfect forward secrecy", "protocol version deprecation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Transport_Layer_Security", "https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Security_Cheat_Sheet.html" }, .trust = 0.8 },
    .{ .name = "authenticated-encryption", .pack = packUrl("authenticated-encryption"), .tags = &.{ "authenticated encryption", "aead cipher mode", "galois counter mode", "encrypt then mac" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Authenticated_encryption", "https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html" }, .trust = 0.8 },
    // — mega-pack wave 6: framework/platform/deep-topic tail — desktop GUI toolkits, more
    // backend frameworks, AWS/Azure/GCP service catalogs, more DB engines, ML/LLM techniques,
    // PL theory, embedded RTOS/safety, advanced rendering/media, systems-security hardening,
    // and industrial protocols. Registry tags, bare-word filtered; trust 0.8. —
    .{ .name = "qt-framework", .pack = packUrl("qt-framework"), .tags = &.{ "qt framework", "qt widgets", "signal slot mechanism", "cross-platform toolkit" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Qt_(software)", "https://doc.qt.io/qt-6/qtwidgets-index.html" }, .trust = 0.8 },
    .{ .name = "gtk-toolkit", .pack = packUrl("gtk-toolkit"), .tags = &.{ "gtk toolkit", "gobject type system", "glib library", "gnome widgets" }, .seeds = &.{"https://en.wikipedia.org/wiki/GTK"}, .trust = 0.8 },
    .{ .name = "electron-framework", .pack = packUrl("electron-framework"), .tags = &.{ "electron framework", "chromium desktop app", "node desktop runtime", "web technology packaging" }, .seeds = &.{"https://en.wikipedia.org/wiki/Electron_(software_framework)"}, .trust = 0.8 },
    .{ .name = "tauri-framework", .pack = packUrl("tauri-framework"), .tags = &.{ "tauri framework", "rust desktop shell", "webview app", "lightweight bundle" }, .seeds = &.{"https://en.wikipedia.org/wiki/WebView"}, .trust = 0.8 },
    .{ .name = "wpf-xaml", .pack = packUrl("wpf-xaml"), .tags = &.{ "wpf xaml", "windows presentation foundation", "xaml markup", "data binding pipeline" }, .seeds = &.{"https://en.wikipedia.org/wiki/Windows_Presentation_Foundation"}, .trust = 0.8 },
    .{ .name = "avalonia-ui", .pack = packUrl("avalonia-ui"), .tags = &.{ "avalonia toolkit", "cross-platform xaml", "skia rendering ui", "dotnet desktop framework" }, .seeds = &.{"https://en.wikipedia.org/wiki/Extensible_Application_Markup_Language"}, .trust = 0.8 },
    .{ .name = "dear-imgui", .pack = packUrl("dear-imgui"), .tags = &.{ "dear imgui", "immediate mode gui", "bloat-free interface", "debug tooling overlay" }, .seeds = &.{"https://en.wikipedia.org/wiki/Immediate_mode_(computer_graphics)"}, .trust = 0.8 },
    .{ .name = "react-native", .pack = packUrl("react-native"), .tags = &.{ "react native", "javascript native bridge", "mobile component tree", "hot reload workflow" }, .seeds = &.{"https://en.wikipedia.org/wiki/React_Native"}, .trust = 0.8 },
    .{ .name = "ionic-framework", .pack = packUrl("ionic-framework"), .tags = &.{ "ionic framework", "hybrid mobile toolkit", "web component controls", "cordova capacitor shell" }, .seeds = &.{"https://en.wikipedia.org/wiki/Ionic_(mobile_app_framework)"}, .trust = 0.8 },
    .{ .name = "java-swing", .pack = packUrl("java-swing"), .tags = &.{ "java swing", "swing components", "pluggable look and feel", "lightweight java widgets" }, .seeds = &.{"https://en.wikipedia.org/wiki/Swing_(Java)"}, .trust = 0.8 },
    .{ .name = "rails-deep", .pack = packUrl("rails-deep"), .tags = &.{ "ruby on rails", "rails active record", "convention over configuration", "rails mvc framework" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Ruby_on_Rails", "https://guides.rubyonrails.org/active_record_basics.html" }, .trust = 0.8 },
    .{ .name = "phoenix-liveview", .pack = packUrl("phoenix-liveview"), .tags = &.{ "phoenix liveview elixir", "server rendered interactivity", "elixir web framework", "liveview stateful process" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Phoenix_(web_framework)", "https://hexdocs.pm/phoenix_live_view/welcome.html" }, .trust = 0.8 },
    .{ .name = "litestar-python", .pack = packUrl("litestar-python"), .tags = &.{ "litestar python framework", "asgi python framework", "python type hints api", "litestar dependency injection" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Python_(programming_language)", "https://docs.litestar.dev/2/" }, .trust = 0.8 },
    .{ .name = "akka-http-scala", .pack = packUrl("akka-http-scala"), .tags = &.{ "akka http scala", "akka actor streams", "scala reactive http", "akka routing directives" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Akka_(toolkit)", "https://doc.akka.io/libraries/akka-http/current/introduction.html" }, .trust = 0.8 },
    .{ .name = "aws-sagemaker", .pack = packUrl("aws-sagemaker"), .tags = &.{ "aws sagemaker", "managed machine learning", "ml training platform", "model deployment service" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_SageMaker"}, .trust = 0.8 },
    .{ .name = "aws-bedrock", .pack = packUrl("aws-bedrock"), .tags = &.{ "aws bedrock", "amazon bedrock", "managed foundation models", "generative ai service" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_Bedrock"}, .trust = 0.8 },
    .{ .name = "aws-fargate", .pack = packUrl("aws-fargate"), .tags = &.{ "aws fargate", "serverless containers", "managed container compute", "container orchestration" }, .seeds = &.{"https://en.wikipedia.org/wiki/Serverless_computing"}, .trust = 0.8 },
    .{ .name = "aws-aurora", .pack = packUrl("aws-aurora"), .tags = &.{ "aws aurora", "amazon aurora", "managed relational database", "cloud-native database" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_Aurora"}, .trust = 0.8 },
    .{ .name = "aws-glue", .pack = packUrl("aws-glue"), .tags = &.{ "aws glue", "amazon glue", "managed etl service", "serverless data integration" }, .seeds = &.{"https://en.wikipedia.org/wiki/AWS_Glue"}, .trust = 0.8 },
    .{ .name = "aws-athena", .pack = packUrl("aws-athena"), .tags = &.{ "aws athena", "amazon athena", "serverless sql query", "interactive query service" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_Athena"}, .trust = 0.8 },
    .{ .name = "aws-cognito", .pack = packUrl("aws-cognito"), .tags = &.{ "aws cognito", "amazon cognito", "user authentication service", "identity pools" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_Cognito"}, .trust = 0.8 },
    .{ .name = "aws-eventbridge", .pack = packUrl("aws-eventbridge"), .tags = &.{ "aws eventbridge", "amazon eventbridge", "serverless event bus", "event routing" }, .seeds = &.{"https://en.wikipedia.org/wiki/Event-driven_architecture"}, .trust = 0.8 },
    .{ .name = "aws-secrets-manager", .pack = packUrl("aws-secrets-manager"), .tags = &.{ "aws secrets manager", "secret rotation", "credential management", "cloud secrets store" }, .seeds = &.{"https://en.wikipedia.org/wiki/Key_management"}, .trust = 0.8 },
    .{ .name = "aws-guardduty", .pack = packUrl("aws-guardduty"), .tags = &.{ "aws guardduty", "amazon guardduty", "cloud threat detection", "intelligent threat monitoring" }, .seeds = &.{"https://en.wikipedia.org/wiki/Intrusion_detection_system"}, .trust = 0.8 },
    .{ .name = "aws-redshift-deep", .pack = packUrl("aws-redshift-deep"), .tags = &.{ "aws redshift", "amazon redshift", "cloud data warehouse", "columnar analytics" }, .seeds = &.{"https://en.wikipedia.org/wiki/Amazon_Redshift"}, .trust = 0.8 },
    .{ .name = "azure-aks", .pack = packUrl("azure-aks"), .tags = &.{ "azure aks", "azure kubernetes service", "managed kubernetes azure", "aks cluster" }, .seeds = &.{"https://en.wikipedia.org/wiki/Microsoft_Azure"}, .trust = 0.8 },
    .{ .name = "azure-openai-service", .pack = packUrl("azure-openai-service"), .tags = &.{ "azure openai service", "managed llm azure", "generative ai azure", "gpt on azure" }, .seeds = &.{"https://en.wikipedia.org/wiki/Large_language_model"}, .trust = 0.8 },
    .{ .name = "azure-machine-learning", .pack = packUrl("azure-machine-learning"), .tags = &.{ "azure machine learning", "mlops azure", "model training azure", "ml lifecycle service" }, .seeds = &.{"https://en.wikipedia.org/wiki/MLOps"}, .trust = 0.8 },
    .{ .name = "azure-service-bus", .pack = packUrl("azure-service-bus"), .tags = &.{ "azure service bus", "message broker azure", "message queue azure", "enterprise messaging" }, .seeds = &.{"https://en.wikipedia.org/wiki/Message_broker"}, .trust = 0.8 },
    .{ .name = "gcp-gke", .pack = packUrl("gcp-gke"), .tags = &.{ "google kubernetes engine", "gke cluster", "managed kubernetes gcp", "gke autopilot" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cluster_(computing)"}, .trust = 0.8 },
    .{ .name = "gcp-cloud-run", .pack = packUrl("gcp-cloud-run"), .tags = &.{ "gcp cloud run", "serverless containers gcp", "knative runtime", "stateless containers gcp" }, .seeds = &.{"https://en.wikipedia.org/wiki/Serverless_computing"}, .trust = 0.8 },
    .{ .name = "gcp-vertex-ai", .pack = packUrl("gcp-vertex-ai"), .tags = &.{ "gcp vertex ai", "unified ml platform gcp", "model deployment vertex", "ml pipelines google" }, .seeds = &.{"https://en.wikipedia.org/wiki/Machine_learning"}, .trust = 0.8 },
    .{ .name = "gcp-spanner", .pack = packUrl("gcp-spanner"), .tags = &.{ "gcp cloud spanner", "globally distributed database", "newsql database gcp", "horizontally scalable sql" }, .seeds = &.{"https://en.wikipedia.org/wiki/Spanner_(database)"}, .trust = 0.8 },
    .{ .name = "gcp-dataflow", .pack = packUrl("gcp-dataflow"), .tags = &.{ "gcp cloud dataflow", "stream batch processing gcp", "apache beam runner", "data pipeline google" }, .seeds = &.{"https://en.wikipedia.org/wiki/Apache_Beam"}, .trust = 0.8 },
    .{ .name = "apache-ignite", .pack = packUrl("apache-ignite"), .tags = &.{ "apache ignite", "in-memory data grid", "distributed cache", "ignite compute grid" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Apache_Ignite", "https://ignite.apache.org/docs/latest/" }, .trust = 0.8 },
    .{ .name = "hazelcast-imdg", .pack = packUrl("hazelcast-imdg"), .tags = &.{ "hazelcast platform", "in-memory data grid", "distributed computing", "hazelcast imdg" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Hazelcast", "https://docs.hazelcast.com/hazelcast/latest/" }, .trust = 0.8 },
    .{ .name = "aerospike-db", .pack = packUrl("aerospike-db"), .tags = &.{ "aerospike database", "flash-optimized database", "key-value store", "real-time database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Aerospike", "https://aerospike.com/docs/" }, .trust = 0.8 },
    .{ .name = "dgraph", .pack = packUrl("dgraph"), .tags = &.{ "dgraph database", "distributed graph database", "dql query language", "graphql database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Graph_database", "https://docs.dgraph.io/" }, .trust = 0.8 },
    .{ .name = "surrealdb", .pack = packUrl("surrealdb"), .tags = &.{ "surrealdb", "multi-model database", "surrealql query language", "document-graph database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Multi-model_database", "https://surrealdb.com/docs/surrealdb" }, .trust = 0.8 },
    .{ .name = "questdb", .pack = packUrl("questdb"), .tags = &.{ "questdb database", "time series database", "sql time series", "column-oriented dbms" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Time_series_database", "https://questdb.com/docs/" }, .trust = 0.8 },
    .{ .name = "airbyte-integration", .pack = packUrl("airbyte-integration"), .tags = &.{ "airbyte platform", "data integration platform", "elt pipeline", "data connectors" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Extract,_transform,_load", "https://docs.airbyte.com/" }, .trust = 0.8 },
    .{ .name = "fivetran-integration", .pack = packUrl("fivetran-integration"), .tags = &.{ "fivetran connector", "managed data pipeline", "automated elt", "data connectors" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Extract,_transform,_load", "https://fivetran.com/docs/getting-started" }, .trust = 0.8 },
    .{ .name = "singlestore", .pack = packUrl("singlestore"), .tags = &.{ "singlestore database", "memsql database", "distributed sql", "htap database" }, .seeds = &.{ "https://en.wikipedia.org/wiki/SingleStore", "https://docs.singlestore.com/" }, .trust = 0.8 },
    .{ .name = "flash-attention", .pack = packUrl("flash-attention"), .tags = &.{ "flash attention", "efficient attention", "gpu attention kernel", "memory bandwidth bound", "fused softmax kernel" }, .seeds = &.{"https://en.wikipedia.org/wiki/FlashAttention"}, .trust = 0.8 },
    .{ .name = "speculative-decoding", .pack = packUrl("speculative-decoding"), .tags = &.{ "speculative decoding", "draft model verification", "llm inference acceleration", "parallel token proposal", "assisted generation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Speculative_decoding"}, .trust = 0.8 },
    .{ .name = "gptq-quantization", .pack = packUrl("gptq-quantization"), .tags = &.{ "post training quantization", "weight only quantization", "layer wise quantization", "gptq method", "low bit inference" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quantization_(signal_processing)"}, .trust = 0.8 },
    .{ .name = "react-agent-prompting", .pack = packUrl("react-agent-prompting"), .tags = &.{ "react agent prompting", "reason and act loop", "tool augmented reasoning", "interleaved thought action", "llm agent loop" }, .seeds = &.{"https://en.wikipedia.org/wiki/Software_agent"}, .trust = 0.8 },
    .{ .name = "chain-of-thought-prompting", .pack = packUrl("chain-of-thought-prompting"), .tags = &.{ "chain of thought prompting", "step by step reasoning", "intermediate reasoning steps", "reasoning trace elicitation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Chain-of-thought_prompting"}, .trust = 0.8 },
    .{ .name = "tool-use-agents", .pack = packUrl("tool-use-agents"), .tags = &.{ "tool using agent", "external tool augmentation", "api calling agent", "action tool selection", "environment interaction loop" }, .seeds = &.{"https://en.wikipedia.org/wiki/Software_agent"}, .trust = 0.8 },
    .{ .name = "named-entity-recognition", .pack = packUrl("named-entity-recognition"), .tags = &.{ "named entity recognition", "entity span tagging", "sequence labeling task", "person location tagging", "entity type classification" }, .seeds = &.{"https://en.wikipedia.org/wiki/Named-entity_recognition"}, .trust = 0.8 },
    .{ .name = "machine-translation-nlp", .pack = packUrl("machine-translation-nlp"), .tags = &.{ "neural machine translation", "sequence to sequence translation", "cross lingual generation", "attention alignment translation", "bilingual corpus training" }, .seeds = &.{"https://en.wikipedia.org/wiki/Machine_translation"}, .trust = 0.8 },
    .{ .name = "optical-character-recognition", .pack = packUrl("optical-character-recognition"), .tags = &.{ "optical character recognition", "text digitization", "handwriting recognition", "document text extraction", "scanned page reading" }, .seeds = &.{"https://en.wikipedia.org/wiki/Optical_character_recognition"}, .trust = 0.8 },
    .{ .name = "text-summarization", .pack = packUrl("text-summarization"), .tags = &.{ "text summarization", "abstractive summarization", "extractive summarization", "document condensation", "salient sentence selection" }, .seeds = &.{"https://en.wikipedia.org/wiki/Automatic_summarization"}, .trust = 0.8 },
    .{ .name = "operational-semantics", .pack = packUrl("operational-semantics"), .tags = &.{ "operational semantics", "structural operational semantics", "abstract machine", "reduction strategy" }, .seeds = &.{"https://en.wikipedia.org/wiki/Operational_semantics"}, .trust = 0.8 },
    .{ .name = "denotational-semantics", .pack = packUrl("denotational-semantics"), .tags = &.{ "denotational semantics", "domain theory", "scott domain", "semantic domain" }, .seeds = &.{"https://en.wikipedia.org/wiki/Denotational_semantics"}, .trust = 0.8 },
    .{ .name = "dependent-types-pl", .pack = packUrl("dependent-types-pl"), .tags = &.{ "dependent type", "pi type", "dependent product", "type family" }, .seeds = &.{"https://en.wikipedia.org/wiki/Dependent_type"}, .trust = 0.8 },
    .{ .name = "effect-systems", .pack = packUrl("effect-systems"), .tags = &.{ "type and effect system", "computational effect", "effect inference", "side effect tracking" }, .seeds = &.{"https://en.wikipedia.org/wiki/Effect_system"}, .trust = 0.8 },
    .{ .name = "separation-logic", .pack = packUrl("separation-logic"), .tags = &.{ "separation logic", "separating conjunction", "heap assertion", "frame rule" }, .seeds = &.{"https://en.wikipedia.org/wiki/Separation_logic"}, .trust = 0.8 },
    .{ .name = "type-inference-algorithms", .pack = packUrl("type-inference-algorithms"), .tags = &.{ "type inference", "algorithm w", "constraint-based type inference", "principal type" }, .seeds = &.{"https://en.wikipedia.org/wiki/Type_inference"}, .trust = 0.8 },
    .{ .name = "hindley-milner-deep", .pack = packUrl("hindley-milner-deep"), .tags = &.{ "hindley-milner type system", "let-polymorphism", "type scheme", "damas-milner algorithm" }, .seeds = &.{"https://en.wikipedia.org/wiki/Hindley%E2%80%93Milner_type_system"}, .trust = 0.8 },
    .{ .name = "zephyr-rtos", .pack = packUrl("zephyr-rtos"), .tags = &.{ "zephyr rtos", "zephyr project", "device tree", "kconfig build" }, .seeds = &.{"https://en.wikipedia.org/wiki/Zephyr_(operating_system)"}, .trust = 0.8 },
    .{ .name = "qnx-rtos", .pack = packUrl("qnx-rtos"), .tags = &.{ "qnx neutrino", "qnx microkernel", "message-passing os", "automotive infotainment" }, .seeds = &.{"https://en.wikipedia.org/wiki/QNX"}, .trust = 0.8 },
    .{ .name = "sel4-microkernel", .pack = packUrl("sel4-microkernel"), .tags = &.{ "sel4 microkernel", "formally verified kernel", "capability-based security", "isabelle proof" }, .seeds = &.{"https://en.wikipedia.org/wiki/SeL4"}, .trust = 0.8 },
    .{ .name = "autosar-classic", .pack = packUrl("autosar-classic"), .tags = &.{ "autosar classic", "autosar rte", "basic software layer", "automotive software architecture" }, .seeds = &.{"https://en.wikipedia.org/wiki/AUTOSAR"}, .trust = 0.8 },
    .{ .name = "misra-c", .pack = packUrl("misra-c"), .tags = &.{ "misra c", "safety-critical coding", "automotive c guidelines", "cert c standard" }, .seeds = &.{"https://en.wikipedia.org/wiki/MISRA_C"}, .trust = 0.8 },
    .{ .name = "functional-safety-concepts", .pack = packUrl("functional-safety-concepts"), .tags = &.{ "functional safety", "hazard analysis", "fail-safe design", "redundancy engineering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Functional_safety"}, .trust = 0.8 },
    .{ .name = "do-178c", .pack = packUrl("do-178c"), .tags = &.{ "do-178c", "airborne software", "dal assurance level", "avionics certification" }, .seeds = &.{"https://en.wikipedia.org/wiki/DO-178C"}, .trust = 0.8 },
    .{ .name = "temporal-antialiasing", .pack = packUrl("temporal-antialiasing"), .tags = &.{ "temporal antialiasing", "taa rendering", "temporal reprojection", "motion vector rendering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Temporal_anti-aliasing"}, .trust = 0.8 },
    .{ .name = "dlss-upscaling", .pack = packUrl("dlss-upscaling"), .tags = &.{ "deep learning super sampling", "dlss upscaling", "neural image upscaling", "temporal upscaling reconstruction" }, .seeds = &.{"https://en.wikipedia.org/wiki/Deep_learning_super_sampling"}, .trust = 0.8 },
    .{ .name = "virtual-geometry-nanite", .pack = packUrl("virtual-geometry-nanite"), .tags = &.{ "virtual geometry rendering", "nanite virtualized geometry", "cluster level of detail", "micropolygon rendering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Level_of_detail_(computer_graphics)"}, .trust = 0.8 },
    .{ .name = "subsurface-scattering", .pack = packUrl("subsurface-scattering"), .tags = &.{ "subsurface scattering", "translucent material rendering", "skin shading scattering", "diffusion profile rendering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Subsurface_scattering"}, .trust = 0.8 },
    .{ .name = "vvc-h266", .pack = packUrl("vvc-h266"), .tags = &.{ "versatile video coding", "h.266 codec", "vvc coding tree unit", "vvc video compression" }, .seeds = &.{"https://en.wikipedia.org/wiki/Versatile_Video_Coding"}, .trust = 0.8 },
    .{ .name = "convolution-reverb", .pack = packUrl("convolution-reverb"), .tags = &.{ "convolution reverb", "impulse response reverb", "fir convolution audio", "overlap add convolution" }, .seeds = &.{"https://en.wikipedia.org/wiki/Convolution_reverb"}, .trust = 0.8 },
    .{ .name = "nurbs-surfaces", .pack = packUrl("nurbs-surfaces"), .tags = &.{ "nurbs surface", "non-uniform rational b-spline", "nurbs control point", "b-spline surface modeling" }, .seeds = &.{"https://en.wikipedia.org/wiki/Non-uniform_rational_B-spline"}, .trust = 0.8 },
    .{ .name = "memory-safety", .pack = packUrl("memory-safety"), .tags = &.{ "memory safety", "spatial memory safety", "temporal memory safety", "memory safe language" }, .seeds = &.{"https://en.wikipedia.org/wiki/Memory_safety"}, .trust = 0.8 },
    .{ .name = "spectre-mitigation", .pack = packUrl("spectre-mitigation"), .tags = &.{ "spectre mitigation", "speculative execution defense", "cpu side channel defense", "branch predictor hardening" }, .seeds = &.{"https://en.wikipedia.org/wiki/Spectre_(security_vulnerability)"}, .trust = 0.8 },
    .{ .name = "slsa-framework", .pack = packUrl("slsa-framework"), .tags = &.{ "slsa provenance framework", "build integrity levels", "supply chain provenance", "hermetic build attestation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Supply_chain_attack", "https://slsa.dev/spec/v1.0/levels" }, .trust = 0.8 },
    .{ .name = "sigstore-signing", .pack = packUrl("sigstore-signing"), .tags = &.{ "sigstore keyless signing", "transparency log signing", "artifact signature verification", "ephemeral signing certificate" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Code_signing", "https://docs.sigstore.dev/about/overview/" }, .trust = 0.8 },
    .{ .name = "seccomp-sandboxing", .pack = packUrl("seccomp-sandboxing"), .tags = &.{ "seccomp system call filtering", "syscall allowlist sandbox", "berkeley packet filter seccomp", "process privilege reduction" }, .seeds = &.{"https://en.wikipedia.org/wiki/Seccomp"}, .trust = 0.8 },
    .{ .name = "selinux-policy", .pack = packUrl("selinux-policy"), .tags = &.{ "selinux type enforcement", "security enhanced linux policy", "mandatory access control label", "domain transition policy" }, .seeds = &.{"https://en.wikipedia.org/wiki/Security-Enhanced_Linux"}, .trust = 0.8 },
    .{ .name = "kubernetes-pod-security", .pack = packUrl("kubernetes-pod-security"), .tags = &.{ "pod security standards", "pod security admission", "restricted pod profile", "workload privilege constraint" }, .seeds = &.{"https://en.wikipedia.org/wiki/Kubernetes"}, .trust = 0.8 },
    .{ .name = "reproducible-builds", .pack = packUrl("reproducible-builds"), .tags = &.{ "reproducible build determinism", "bit for bit build reproducibility", "deterministic compilation", "build environment normalization" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Reproducible_builds", "https://reproducible-builds.org/docs/" }, .trust = 0.8 },
    .{ .name = "profinet", .pack = packUrl("profinet"), .tags = &.{ "industrial ethernet", "real-time fieldbus", "profinet io" }, .seeds = &.{"https://en.wikipedia.org/wiki/PROFINET"}, .trust = 0.8 },
    .{ .name = "ethercat", .pack = packUrl("ethercat"), .tags = &.{ "ethercat protocol", "industrial ethernet", "distributed clocks" }, .seeds = &.{"https://en.wikipedia.org/wiki/EtherCAT"}, .trust = 0.8 },
    .{ .name = "modbus-protocol", .pack = packUrl("modbus-protocol"), .tags = &.{ "modbus protocol", "modbus rtu", "modbus tcp", "serial fieldbus" }, .seeds = &.{"https://en.wikipedia.org/wiki/Modbus"}, .trust = 0.8 },
    .{ .name = "opc-ua-deep", .pack = packUrl("opc-ua-deep"), .tags = &.{ "opc ua", "opc unified architecture", "industrial interoperability", "opc ua information model" }, .seeds = &.{"https://en.wikipedia.org/wiki/OPC_Unified_Architecture"}, .trust = 0.8 },
    .{ .name = "bacnet", .pack = packUrl("bacnet"), .tags = &.{ "bacnet building automation", "bacnet protocol", "building automation network", "direct digital control" }, .seeds = &.{"https://en.wikipedia.org/wiki/BACnet"}, .trust = 0.8 },
    .{ .name = "iec-61850", .pack = packUrl("iec-61850"), .tags = &.{ "iec 61850", "substation automation", "goose messaging", "intelligent electronic device" }, .seeds = &.{"https://en.wikipedia.org/wiki/IEC_61850"}, .trust = 0.8 },
    .{ .name = "lorawan-deep", .pack = packUrl("lorawan-deep"), .tags = &.{ "lorawan protocol", "lora wide-area network", "lpwan networking", "chirp spread spectrum radio" }, .seeds = &.{"https://en.wikipedia.org/wiki/LoRaWAN"}, .trust = 0.8 },
    .{ .name = "iec-62443-security", .pack = packUrl("iec-62443-security"), .tags = &.{ "iec 62443", "industrial automation security", "ot security standard", "control system cybersecurity" }, .seeds = &.{"https://en.wikipedia.org/wiki/IEC_62443"}, .trust = 0.8 },
    // — mega-pack wave 7: deep-theory & specialist tail — applied math, advanced CS theory,
    // named algorithms, deep statistics, deep web-platform APIs, data-viz, deep devops/SRE,
    // more networking, sensors/hardware, identity/privacy/OT security, biotech/structural
    // biology, and more verticals (aero/auto/energy/manufacturing). Registry tags; trust 0.8. —
    .{ .name = "special-functions", .pack = packUrl("special-functions"), .tags = &.{ "special functions", "bessel functions", "gamma function", "error function" }, .seeds = &.{"https://en.wikipedia.org/wiki/Special_functions"}, .trust = 0.8 },
    .{ .name = "laplace-transform", .pack = packUrl("laplace-transform"), .tags = &.{ "laplace transform", "inverse laplace transform", "transfer function", "final value theorem" }, .seeds = &.{"https://en.wikipedia.org/wiki/Laplace_transform"}, .trust = 0.8 },
    .{ .name = "spectral-methods-numerical", .pack = packUrl("spectral-methods-numerical"), .tags = &.{ "spectral method", "pseudo-spectral method", "galerkin method", "collocation method" }, .seeds = &.{"https://en.wikipedia.org/wiki/Spectral_method"}, .trust = 0.8 },
    .{ .name = "optimal-transport", .pack = packUrl("optimal-transport"), .tags = &.{ "optimal transport", "wasserstein metric", "earth mover's distance", "kantorovich metric" }, .seeds = &.{"https://en.wikipedia.org/wiki/Transportation_theory_(mathematics)"}, .trust = 0.8 },
    .{ .name = "stochastic-differential-equations", .pack = packUrl("stochastic-differential-equations"), .tags = &.{ "stochastic differential equation", "euler-maruyama method", "milstein method", "langevin equation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Stochastic_differential_equation"}, .trust = 0.8 },
    .{ .name = "finite-difference-methods", .pack = packUrl("finite-difference-methods"), .tags = &.{ "finite difference method", "crank-nicolson method", "upwind scheme", "von neumann stability analysis" }, .seeds = &.{"https://en.wikipedia.org/wiki/Finite_difference_method"}, .trust = 0.8 },
    .{ .name = "approximation-algorithms", .pack = packUrl("approximation-algorithms"), .tags = &.{ "approximation algorithm", "approximation ratio", "polynomial-time approximation scheme", "hardness of approximation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Approximation_algorithm"}, .trust = 0.8 },
    .{ .name = "randomized-algorithms-deep", .pack = packUrl("randomized-algorithms-deep"), .tags = &.{ "randomized algorithm", "monte carlo algorithm", "probabilistic method", "chernoff bound" }, .seeds = &.{"https://en.wikipedia.org/wiki/Randomized_algorithm"}, .trust = 0.8 },
    .{ .name = "parameterized-complexity", .pack = packUrl("parameterized-complexity"), .tags = &.{ "parameterized complexity", "fixed parameter tractable", "w hierarchy", "treewidth parameter" }, .seeds = &.{"https://en.wikipedia.org/wiki/Parameterized_complexity"}, .trust = 0.8 },
    .{ .name = "learning-theory-pac", .pack = packUrl("learning-theory-pac"), .tags = &.{ "probably approximately correct", "sample complexity", "pac learnable", "concept class" }, .seeds = &.{"https://en.wikipedia.org/wiki/Probably_approximately_correct_learning"}, .trust = 0.8 },
    .{ .name = "vc-dimension", .pack = packUrl("vc-dimension"), .tags = &.{ "vapnik chervonenkis dimension", "shattering set", "growth function", "sauer shelah lemma" }, .seeds = &.{"https://en.wikipedia.org/wiki/Vapnik%E2%80%93Chervonenkis_dimension"}, .trust = 0.8 },
    .{ .name = "algorithmic-game-theory", .pack = packUrl("algorithmic-game-theory"), .tags = &.{ "algorithmic game theory", "computational equilibrium", "combinatorial auction", "selfish routing" }, .seeds = &.{"https://en.wikipedia.org/wiki/Algorithmic_game_theory"}, .trust = 0.8 },
    .{ .name = "nash-equilibrium-computation", .pack = packUrl("nash-equilibrium-computation"), .tags = &.{ "nash equilibrium computation", "lemke howson algorithm", "ppad complete", "fixed point argument" }, .seeds = &.{"https://en.wikipedia.org/wiki/Nash_equilibrium"}, .trust = 0.8 },
    .{ .name = "stable-matching", .pack = packUrl("stable-matching"), .tags = &.{ "stable matching", "gale shapley algorithm", "stable marriage problem", "hospital residents problem" }, .seeds = &.{"https://en.wikipedia.org/wiki/Stable_marriage_problem"}, .trust = 0.8 },
    .{ .name = "convex-hull-algorithms", .pack = packUrl("convex-hull-algorithms"), .tags = &.{ "convex hull algorithm", "graham scan", "quickhull method", "gift wrapping" }, .seeds = &.{"https://en.wikipedia.org/wiki/Convex_hull_algorithms"}, .trust = 0.8 },
    .{ .name = "delaunay-triangulation-algo", .pack = packUrl("delaunay-triangulation-algo"), .tags = &.{ "delaunay triangulation", "bowyer watson algorithm", "empty circle", "constrained delaunay" }, .seeds = &.{"https://en.wikipedia.org/wiki/Delaunay_triangulation"}, .trust = 0.8 },
    .{ .name = "min-cost-max-flow", .pack = packUrl("min-cost-max-flow"), .tags = &.{ "minimum cost flow", "min cost max flow", "successive shortest path", "cost scaling" }, .seeds = &.{"https://en.wikipedia.org/wiki/Minimum-cost_flow_problem"}, .trust = 0.8 },
    .{ .name = "suffix-automaton", .pack = packUrl("suffix-automaton"), .tags = &.{ "suffix automaton", "directed acyclic word graph", "substring recognition", "minimal automaton" }, .seeds = &.{"https://en.wikipedia.org/wiki/Suffix_automaton"}, .trust = 0.8 },
    .{ .name = "adam-optimizer", .pack = packUrl("adam-optimizer"), .tags = &.{ "adam optimizer", "adaptive moment estimation", "first order optimizer", "bias correction" }, .seeds = &.{"https://en.wikipedia.org/wiki/Stochastic_gradient_descent"}, .trust = 0.8 },
    .{ .name = "quasi-newton-bfgs", .pack = packUrl("quasi-newton-bfgs"), .tags = &.{ "quasi newton method", "bfgs update", "limited memory bfgs", "hessian approximation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Quasi-Newton_method"}, .trust = 0.8 },
    .{ .name = "linear-regression", .pack = packUrl("linear-regression"), .tags = &.{ "linear regression", "ordinary least squares", "regression coefficients", "least squares" }, .seeds = &.{"https://en.wikipedia.org/wiki/Linear_regression"}, .trust = 0.8 },
    .{ .name = "logistic-regression", .pack = packUrl("logistic-regression"), .tags = &.{ "logistic regression", "logit", "odds ratio", "probit model" }, .seeds = &.{"https://en.wikipedia.org/wiki/Logistic_regression"}, .trust = 0.8 },
    .{ .name = "generalized-linear-models", .pack = packUrl("generalized-linear-models"), .tags = &.{ "generalized linear model", "link function", "exponential family", "quasi-likelihood" }, .seeds = &.{"https://en.wikipedia.org/wiki/Generalized_linear_model"}, .trust = 0.8 },
    .{ .name = "survival-analysis", .pack = packUrl("survival-analysis"), .tags = &.{ "survival analysis", "survival function", "data censoring", "hazard function" }, .seeds = &.{"https://en.wikipedia.org/wiki/Survival_analysis"}, .trust = 0.8 },
    .{ .name = "time-series-arima", .pack = packUrl("time-series-arima"), .tags = &.{ "arima", "autoregressive model", "moving-average model", "box jenkins" }, .seeds = &.{"https://en.wikipedia.org/wiki/Autoregressive_integrated_moving_average"}, .trust = 0.8 },
    .{ .name = "garch-models", .pack = packUrl("garch-models"), .tags = &.{ "arch model", "garch", "conditional variance", "volatility clustering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Autoregressive_conditional_heteroskedasticity"}, .trust = 0.8 },
    .{ .name = "markov-chain-monte-carlo-deep", .pack = packUrl("markov-chain-monte-carlo-deep"), .tags = &.{ "markov chain monte carlo", "detailed balance", "ergodicity", "burn-in" }, .seeds = &.{"https://en.wikipedia.org/wiki/Markov_chain_Monte_Carlo"}, .trust = 0.8 },
    .{ .name = "mixed-effects-models", .pack = packUrl("mixed-effects-models"), .tags = &.{ "mixed model", "random effects", "fixed effects", "intraclass correlation" }, .seeds = &.{"https://en.wikipedia.org/wiki/Mixed_model"}, .trust = 0.8 },
    .{ .name = "experimental-design", .pack = packUrl("experimental-design"), .tags = &.{ "design of experiments", "statistical blocking", "treatment randomization", "experimental replication" }, .seeds = &.{"https://en.wikipedia.org/wiki/Design_of_experiments"}, .trust = 0.8 },
    .{ .name = "bootstrap-resampling", .pack = packUrl("bootstrap-resampling"), .tags = &.{ "bootstrapping statistics", "confidence interval", "empirical distribution", "standard error" }, .seeds = &.{"https://en.wikipedia.org/wiki/Bootstrapping_(statistics)"}, .trust = 0.8 },
    .{ .name = "web-workers", .pack = packUrl("web-workers"), .tags = &.{ "web workers", "background threads browser", "worker global scope", "dedicated worker thread" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Web_worker", "https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API" }, .trust = 0.8 },
    .{ .name = "web-crypto-api", .pack = packUrl("web-crypto-api"), .tags = &.{ "web crypto api", "subtle crypto operations", "cryptographic key generation", "secure random values" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Cryptography", "https://developer.mozilla.org/en-US/docs/Web/API/Web_Crypto_API" }, .trust = 0.8 },
    .{ .name = "web-audio-api", .pack = packUrl("web-audio-api"), .tags = &.{ "web audio api", "audio node graph", "audio context processing", "gain oscillator node" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Digital_audio", "https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API" }, .trust = 0.8 },
    .{ .name = "webcodecs-api", .pack = packUrl("webcodecs-api"), .tags = &.{ "webcodecs api", "low-level frame encode", "video frame decode", "encoded audio chunk" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Data_compression", "https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API" }, .trust = 0.8 },
    .{ .name = "resize-observer", .pack = packUrl("resize-observer"), .tags = &.{ "resize observer api", "element size change callback", "content box resize", "observe box dimensions" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Observer_pattern", "https://developer.mozilla.org/en-US/docs/Web/API/ResizeObserver" }, .trust = 0.8 },
    .{ .name = "custom-elements-deep", .pack = packUrl("custom-elements-deep"), .tags = &.{ "custom elements lifecycle", "connected callback reaction", "attribute changed callback", "element upgrade reaction" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Web_Components", "https://developer.mozilla.org/en-US/docs/Web/API/CustomElementRegistry" }, .trust = 0.8 },
    .{ .name = "mutation-observer", .pack = packUrl("mutation-observer"), .tags = &.{ "mutation observer api", "dom tree change watch", "mutation record list", "observe child list" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Document_Object_Model", "https://developer.mozilla.org/en-US/docs/Web/API/MutationObserver" }, .trust = 0.8 },
    .{ .name = "statistical-charts", .pack = packUrl("statistical-charts"), .tags = &.{ "box plot", "violin plot", "statistical graphics", "distribution chart" }, .seeds = &.{"https://en.wikipedia.org/wiki/Box_plot"}, .trust = 0.8 },
    .{ .name = "heatmap-viz", .pack = packUrl("heatmap-viz"), .tags = &.{ "heat map", "cluster analysis", "dendrogram", "correlation matrix" }, .seeds = &.{"https://en.wikipedia.org/wiki/Heat_map"}, .trust = 0.8 },
    .{ .name = "network-graph-viz", .pack = packUrl("network-graph-viz"), .tags = &.{ "graph drawing", "vertex layout", "graph theory", "network diagram" }, .seeds = &.{"https://en.wikipedia.org/wiki/Graph_drawing"}, .trust = 0.8 },
    .{ .name = "choropleth-maps", .pack = packUrl("choropleth-maps"), .tags = &.{ "choropleth map", "thematic map", "shaded regions", "areal data" }, .seeds = &.{"https://en.wikipedia.org/wiki/Choropleth_map"}, .trust = 0.8 },
    .{ .name = "grammar-of-graphics", .pack = packUrl("grammar-of-graphics"), .tags = &.{ "grammar of graphics", "ggplot2", "semiology of graphics", "layered grammar" }, .seeds = &.{"https://en.wikipedia.org/wiki/The_Grammar_of_Graphics"}, .trust = 0.8 },
    .{ .name = "dashboard-design", .pack = packUrl("dashboard-design"), .tags = &.{ "information dashboard", "business dashboard", "kpi display", "bullet graph" }, .seeds = &.{"https://en.wikipedia.org/wiki/Dashboard_(business)"}, .trust = 0.8 },
    .{ .name = "sankey-diagrams", .pack = packUrl("sankey-diagrams"), .tags = &.{ "sankey diagram", "alluvial diagram", "flow diagram", "flux visualization" }, .seeds = &.{"https://en.wikipedia.org/wiki/Sankey_diagram"}, .trust = 0.8 },
    .{ .name = "distributed-tracing-deep", .pack = packUrl("distributed-tracing-deep"), .tags = &.{ "distributed tracing", "span context propagation", "trace sampling", "request correlation" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Tracing_(software)", "https://opentelemetry.io/docs/concepts/signals/traces/" }, .trust = 0.8 },
    .{ .name = "service-level-objectives", .pack = packUrl("service-level-objectives"), .tags = &.{ "service level objective", "service level indicator", "reliability target", "availability threshold" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Service-level_objective", "https://sre.google/sre-book/service-level-objectives/" }, .trust = 0.8 },
    .{ .name = "service-mesh-deep", .pack = packUrl("service-mesh-deep"), .tags = &.{ "service mesh data plane", "mesh control plane", "mutual tls mesh", "east west traffic" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Service_mesh", "https://istio.io/latest/docs/concepts/traffic-management/" }, .trust = 0.8 },
    .{ .name = "kubernetes-operators", .pack = packUrl("kubernetes-operators"), .tags = &.{ "kubernetes operator", "operator reconcile loop", "domain specific controller", "operator pattern" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Kubernetes", "https://kubernetes.io/docs/concepts/extend-kubernetes/operator/" }, .trust = 0.8 },
    .{ .name = "platform-engineering", .pack = packUrl("platform-engineering"), .tags = &.{ "platform engineering", "cognitive load reduction", "product mindset infrastructure", "platform team" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DevOps", "https://platformengineering.org/blog/what-is-platform-engineering" }, .trust = 0.8 },
    .{ .name = "dora-metrics", .pack = packUrl("dora-metrics"), .tags = &.{ "dora metrics", "deployment frequency lead time", "change failure rate", "delivery performance measure" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DevOps", "https://dora.dev/guides/dora-metrics-four-keys/" }, .trust = 0.8 },
    .{ .name = "gitops-workflows", .pack = packUrl("gitops-workflows"), .tags = &.{ "gitops workflow", "git as source of truth", "pull based reconciliation", "declarative delivery" }, .seeds = &.{ "https://en.wikipedia.org/wiki/DevOps", "https://argo-cd.readthedocs.io/en/stable/core_concepts/" }, .trust = 0.8 },
    .{ .name = "progressive-delivery-deep", .pack = packUrl("progressive-delivery-deep"), .tags = &.{ "progressive delivery", "automated canary analysis", "gradual traffic shift", "release promotion gate" }, .seeds = &.{ "https://en.wikipedia.org/wiki/Continuous_delivery", "https://argo-rollouts.readthedocs.io/en/stable/" }, .trust = 0.8 },
    .{ .name = "network-automation", .pack = packUrl("network-automation"), .tags = &.{ "network automation", "zero touch provisioning", "config management", "net devops" }, .seeds = &.{"https://en.wikipedia.org/wiki/Network_Automation"}, .trust = 0.8 },
    .{ .name = "netconf-yang", .pack = packUrl("netconf-yang"), .tags = &.{ "netconf protocol", "yang modeling", "config datastore", "model-driven config" }, .seeds = &.{"https://en.wikipedia.org/wiki/NETCONF"}, .trust = 0.8 },
    .{ .name = "sd-wan", .pack = packUrl("sd-wan"), .tags = &.{ "software-defined wan", "wan edge", "overlay transport", "application-aware routing" }, .seeds = &.{"https://en.wikipedia.org/wiki/SD-WAN"}, .trust = 0.8 },
    .{ .name = "zero-trust-network-access", .pack = packUrl("zero-trust-network-access"), .tags = &.{ "zero trust access", "zero trust model", "least privilege access", "identity-aware proxy" }, .seeds = &.{"https://en.wikipedia.org/wiki/Zero_trust_security_model"}, .trust = 0.8 },
    .{ .name = "time-sensitive-networking", .pack = packUrl("time-sensitive-networking"), .tags = &.{ "time-sensitive networking", "bounded latency", "deterministic ethernet", "scheduled traffic" }, .seeds = &.{"https://en.wikipedia.org/wiki/Time-Sensitive_Networking"}, .trust = 0.8 },
    .{ .name = "wifi-7", .pack = packUrl("wifi-7"), .tags = &.{ "wi-fi 7", "802.11be standard", "multi-link operation", "extremely high throughput" }, .seeds = &.{"https://en.wikipedia.org/wiki/Wi-Fi_7"}, .trust = 0.8 },
    .{ .name = "private-5g", .pack = packUrl("private-5g"), .tags = &.{ "private 5g", "enterprise cellular", "industrial iot connectivity", "dedicated mobile network" }, .seeds = &.{"https://en.wikipedia.org/wiki/5G"}, .trust = 0.8 },
    .{ .name = "open-ran", .pack = packUrl("open-ran"), .tags = &.{ "open ran", "disaggregated radio", "ran interfaces", "virtualized base station" }, .seeds = &.{"https://en.wikipedia.org/wiki/Open_RAN"}, .trust = 0.8 },
    .{ .name = "imu-sensors", .pack = packUrl("imu-sensors"), .tags = &.{ "inertial measurement unit", "sensor fusion", "attitude heading reference", "dead reckoning" }, .seeds = &.{"https://en.wikipedia.org/wiki/Inertial_measurement_unit"}, .trust = 0.8 },
    .{ .name = "stepper-motors-deep", .pack = packUrl("stepper-motors-deep"), .tags = &.{ "stepper motor", "microstepping drive", "switched reluctance motor", "holding torque" }, .seeds = &.{"https://en.wikipedia.org/wiki/Stepper_motor"}, .trust = 0.8 },
    .{ .name = "brushless-dc-motors", .pack = packUrl("brushless-dc-motors"), .tags = &.{ "brushless dc motor", "field-oriented control", "permanent magnet synchronous motor", "commutation scheme" }, .seeds = &.{"https://en.wikipedia.org/wiki/Brushless_DC_electric_motor"}, .trust = 0.8 },
    .{ .name = "lithium-battery-management", .pack = packUrl("lithium-battery-management"), .tags = &.{ "lithium-ion battery", "battery management system", "state of charge", "battery balancing" }, .seeds = &.{"https://en.wikipedia.org/wiki/Lithium-ion_battery"}, .trust = 0.8 },
    .{ .name = "lidar-sensors-deep", .pack = packUrl("lidar-sensors-deep"), .tags = &.{ "lidar scanning", "optical time-domain reflectometer", "point cloud", "beam steering" }, .seeds = &.{"https://en.wikipedia.org/wiki/Lidar"}, .trust = 0.8 },
    .{ .name = "current-sensing", .pack = packUrl("current-sensing"), .tags = &.{ "current sensor", "current clamp", "rogowski coil", "current transformer" }, .seeds = &.{"https://en.wikipedia.org/wiki/Current_sensor"}, .trust = 0.8 },
    .{ .name = "hall-effect-sensors", .pack = packUrl("hall-effect-sensors"), .tags = &.{ "hall effect sensor", "magnetic field sensing", "wiegand effect", "reed switch" }, .seeds = &.{"https://en.wikipedia.org/wiki/Hall_effect_sensor"}, .trust = 0.8 },
    .{ .name = "privacy-engineering", .pack = packUrl("privacy-engineering"), .tags = &.{ "privacy engineering", "privacy by design", "data minimization", "privacy enhancing technologies" }, .seeds = &.{"https://en.wikipedia.org/wiki/Privacy_engineering"}, .trust = 0.8 },
    .{ .name = "differential-privacy-applied", .pack = packUrl("differential-privacy-applied"), .tags = &.{ "differential privacy", "local differential privacy", "privacy budget epsilon", "randomized response", "statistical disclosure control" }, .seeds = &.{"https://en.wikipedia.org/wiki/Differential_privacy"}, .trust = 0.8 },
    .{ .name = "identity-federation", .pack = packUrl("identity-federation"), .tags = &.{ "identity federation", "federated identity provider", "cross domain sso", "saml federation", "identity and access management" }, .seeds = &.{"https://en.wikipedia.org/wiki/Federated_identity"}, .trust = 0.8 },
    .{ .name = "oauth2-flows-deep", .pack = packUrl("oauth2-flows-deep"), .tags = &.{ "oauth2 authorization flow", "authorization code grant", "access token issuance", "bearer token authentication", "json web token" }, .seeds = &.{"https://en.wikipedia.org/wiki/OAuth"}, .trust = 0.8 },
    .{ .name = "cloud-security-posture-deep", .pack = packUrl("cloud-security-posture-deep"), .tags = &.{ "cloud security posture management", "misconfiguration detection", "compliance drift monitoring", "infrastructure as code scanning", "security baseline enforcement" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cloud_computing_security"}, .trust = 0.8 },
    .{ .name = "iot-security-deep", .pack = packUrl("iot-security-deep"), .tags = &.{ "iot security", "embedded device hardening", "botnet compromise defense", "mirai botnet mitigation", "over the air update" }, .seeds = &.{"https://en.wikipedia.org/wiki/Internet_of_things"}, .trust = 0.8 },
    .{ .name = "ot-security-ics", .pack = packUrl("ot-security-ics"), .tags = &.{ "operational technology security", "industrial control system", "scada protection", "plc security hardening", "critical infrastructure defense" }, .seeds = &.{"https://en.wikipedia.org/wiki/Operational_technology"}, .trust = 0.8 },
    .{ .name = "cryo-em", .pack = packUrl("cryo-em"), .tags = &.{ "cryo-electron microscopy", "single particle analysis", "structural biology", "vitreous ice" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cryogenic_electron_microscopy"}, .trust = 0.8 },
    .{ .name = "alphafold-prediction", .pack = packUrl("alphafold-prediction"), .tags = &.{ "protein structure prediction", "deep learning fold", "contact map", "homology" }, .seeds = &.{"https://en.wikipedia.org/wiki/AlphaFold"}, .trust = 0.8 },
    .{ .name = "structure-based-drug-design", .pack = packUrl("structure-based-drug-design"), .tags = &.{ "rational drug design", "target binding", "receptor pocket", "affinity" }, .seeds = &.{"https://en.wikipedia.org/wiki/Drug_design"}, .trust = 0.8 },
    .{ .name = "crispr-cas9-deep", .pack = packUrl("crispr-cas9-deep"), .tags = &.{ "cas9 nuclease", "guide rna", "protospacer adjacent", "double strand break" }, .seeds = &.{"https://en.wikipedia.org/wiki/Cas9"}, .trust = 0.8 },
    .{ .name = "single-cell-sequencing", .pack = packUrl("single-cell-sequencing"), .tags = &.{ "single cell rna", "cell barcoding", "droplet microfluidics", "unique molecular identifier" }, .seeds = &.{"https://en.wikipedia.org/wiki/Single-cell_sequencing"}, .trust = 0.8 },
    .{ .name = "mrna-vaccines", .pack = packUrl("mrna-vaccines"), .tags = &.{ "messenger rna vaccine", "lipid nanoparticle", "nucleoside modification", "in vitro transcription" }, .seeds = &.{"https://en.wikipedia.org/wiki/MRNA_vaccine"}, .trust = 0.8 },
    .{ .name = "antibody-engineering", .pack = packUrl("antibody-engineering"), .tags = &.{ "engineered antibody", "phage display", "humanization", "single chain" }, .seeds = &.{"https://en.wikipedia.org/wiki/Antibody_engineering"}, .trust = 0.8 },
    .{ .name = "avionics-systems", .pack = packUrl("avionics-systems"), .tags = &.{ "avionics", "flight control systems", "aircraft systems", "fly-by-wire" }, .seeds = &.{"https://en.wikipedia.org/wiki/Avionics"}, .trust = 0.8 },
    .{ .name = "autonomous-vehicles", .pack = packUrl("autonomous-vehicles"), .tags = &.{ "autonomous vehicles", "self-driving car", "vehicular automation", "automated driving" }, .seeds = &.{"https://en.wikipedia.org/wiki/Self-driving_car"}, .trust = 0.8 },
    .{ .name = "self-driving-perception", .pack = packUrl("self-driving-perception"), .tags = &.{ "self-driving perception", "object detection", "semantic segmentation", "simultaneous localization mapping" }, .seeds = &.{"https://en.wikipedia.org/wiki/Computer_vision"}, .trust = 0.8 },
    .{ .name = "drone-uav-systems", .pack = packUrl("drone-uav-systems"), .tags = &.{ "unmanned aerial vehicle", "quadcopter", "first-person view", "ground control station" }, .seeds = &.{"https://en.wikipedia.org/wiki/Unmanned_aerial_vehicle"}, .trust = 0.8 },
    .{ .name = "precision-agriculture", .pack = packUrl("precision-agriculture"), .tags = &.{ "precision agriculture", "variable-rate application", "yield monitoring", "agricultural drones" }, .seeds = &.{"https://en.wikipedia.org/wiki/Precision_agriculture"}, .trust = 0.8 },
    .{ .name = "power-grid-systems", .pack = packUrl("power-grid-systems"), .tags = &.{ "electrical grid", "power transmission", "power distribution", "power-system protection" }, .seeds = &.{"https://en.wikipedia.org/wiki/Electrical_grid"}, .trust = 0.8 },
    .{ .name = "additive-manufacturing", .pack = packUrl("additive-manufacturing"), .tags = &.{ "additive manufacturing", "fused filament fabrication", "selective laser sintering", "stereolithography" }, .seeds = &.{"https://en.wikipedia.org/wiki/3D_printing"}, .trust = 0.8 },
    .{ .name = "construction-bim", .pack = packUrl("construction-bim"), .tags = &.{ "building information modeling", "industry foundation classes", "construction management", "4d bim" }, .seeds = &.{"https://en.wikipedia.org/wiki/Building_information_modeling"}, .trust = 0.8 },
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
