defmodule HttpRouter do
  @moduledoc """
  `HttpRouter` defines an alternate format for `Plug.Router`
  routing. Supports all HTTP methods that `Plug.Router` supports.

  Routes are defined with the form:

      method route [guard], handler, action

  `method` is `get`, `post`, `put`, `patch`, or `delete`, each
  responsible for a single HTTP method. `method` can also be `any`, which will
  match on all HTTP methods. `options` is yet another option for `method`, but
  when using `options`, only a route path and the methods that route path
  supports are needed. `handler` is any valid Elixir module name, and
  `action` is any valid public function defined in the `handler` module.

  `get/3`, `post/3`, `put/3`, `patch/3`, `delete/3`, `options/2`, and `any/3`
  are already built-in as described. `resource/2` exists but will need
  modifications to create everything as noted.

  `raw/4` allows for using custom HTTP methods, allowing your application to be
  HTTP spec compliant.

  `version/2` allows requests to contained endpoints when version exists in
  either `Accept` header or URL (which ever is defined in the app config).

  Extra routes will be added for `*.json`, `*.xml`, etc. requests for optionally
  specifying desired content type without the use of the `Accept` header. These
  match parsing/rendering abilities of HttpRouter.

  ## Example

      defmodule Router do
        use HttpRouter

        # Define one of the versions of the API
        # with a simple version number "1"
        # or following semver "1.0.0"
        # or date of release "2014-09-06"
        version "1" do
          # Define your routes here
          get  "/",               Handlers.V1.Pages, :index
          get  "/pages",          Handlers.V1.Pages, :create
          post "/pages",          Handlers.V1.Pages, :create
          put  "/pages/:page_id" when id == 1,
                                  Handlers.V1.Pages, :update_only_one
          get  "/pages/:page_id", Handlers.V1.Pages, :show

          # Auto-create a full set of routes for resources
          #
          resource :users,        Handlers.V1.User, arg: :user_id
          #
          # Generates:
          #
          # get     "/users",           Handlers.V1.User, :index
          # post    "/users",           Handlers.V1.User, :create
          # get     "/users/:user_id",  Handlers.V1.User, :show
          # put     "/users/:user_id",  Handlers.V1.User, :update
          # patch   "/users/:user_id",  Handlers.V1.User, :patch
          # delete  "/users/:user_id",  Handlers.V1.User, :delete
          #
          # options "/users",           "HEAD,GET,POST"
          # options "/users/:_user_id", "HEAD,GET,PUT,PATCH,DELETE"
        end

        # An updated version of the AP
        version "2" do
          get  "/",               Handlers.V2.Pages,  :index
          post "/pages",          Handlers.V2.Pages,  :create
          get  "/pages/:page_id", Handlers.V2.Pages,  :show
          put  "/pages/:page_id", Handlers.V2.Pages,  :update

          raw :trace, "/trace",   Handlers.V2.Tracer, :trace

          resource :users,        Handlers.V2.User
          resource :groups,       Handlers.V2.Group
        end
      end
  """

  import HttpRouter.Util

  @typep ast :: tuple
  @http_methods [ :get, :post, :put, :patch, :delete, :any ]

  @default_options [
    add_match_details_to_private: true,
    allow_copy_req_content_type: true,
    allow_head: true,
    allow_method_override: true,
    default_content_type: "text/html; charset=utf-8",
    json_decoder: Poison,
    parsers: [:json, :urlencoded, :multipart]
  ]

  ## Macros

  @doc false
  defmacro __using__(opts) do
    opts = @default_options |> Keyword.merge(opts)
    quote do
      import HttpRouter
      import Plug.Builder, only: [plug: 1, plug: 2]
      @before_compile HttpRouter
      @behaviour Plug
      Module.register_attribute(__MODULE__, :plugs, accumulate: true)
      Module.register_attribute(__MODULE__, :version, accumulate: false)
      Module.put_attribute(__MODULE__, :options, unquote(opts))

      # Plugs we want early in the stack
      parsers_opts = [ parsers: unquote(opts[:parsers]) ]
      if :json in parsers_opts[:parsers] do
        parsers_opts = parsers_opts
                        |> Keyword.put(:json_decoder, unquote(opts[:json_decoder]))
      end

      plug Plug.Parsers, parsers_opts
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :options)
    # Plugs we want predefined but aren't necessary to be before
    # user-defined plugs
    defaults = [ { :match, [], true },
                 { :dispatch, [], true } ]

    if options[:allow_copy_req_content_type] == true do
      defaults = [ { :copy_req_content_type, [], true } | defaults ]
    end

    if options[:allow_method_override] == true do
      defaults = [ { Plug.MethodOverride, [], true } | defaults ]
    end

    if options[:allow_head] == true do
      defaults = [ { Plug.Head, [], true } | defaults ]
    end

    plugs = Enum.reverse(defaults) ++
            Module.get_attribute(env.module, :plugs)
    { conn, body } = env |> Plug.Builder.compile(plugs, [])

    quote do
      def init(opts) do
        opts
      end

      def call(conn, opts) do
        do_call(conn, opts)
      end

      if unquote(options[:allow_copy_req_content_type]) == true do
        def copy_req_content_type(conn, _opts) do
          default = unquote(options[:default_content_type])
          content_type = case Plug.Conn.get_req_header conn, "content-type" do
              [content_type] -> content_type
              _ -> default
            end
          conn |> Plug.Conn.put_resp_header("content-type", content_type)
        end
      end

      def match(conn, _opts) do
        plug_route = __MODULE__.do_match(conn.method, conn.path_info)
        Plug.Conn.put_private(conn, :plug_route, plug_route)
      end

      def dispatch(%Plug.Conn{ assigns: assigns } = conn, _opts) do
        Map.get(conn.private, :plug_route).(conn)
      end

      # Our default match so `Plug` doesn't fall on
      # its face when accessing an undefined route.
      def do_match(_,_) do
        fn conn ->
          conn |> Plug.Conn.send_resp(404, "")
        end
      end

      defp do_call(unquote(conn), _), do: unquote(body)
    end
  end

  for verb <- @http_methods do
    @doc """
    Macro for defining `#{verb |> to_string |> String.upcase}` routes.

    ## Arguments

    * `route` - `String|List`
    * `handler` - `Atom`
    * `action` - `Atom`
    """
    @spec unquote(verb)(binary | list, atom, atom) :: ast
    defmacro unquote(verb)(route, handler, action) do
      build_match unquote(verb), route, handler, action, __CALLER__
    end
  end

  @doc """
  Macro for defining `OPTIONS` routes.

  ## Arguments

  * `route` - `String|List`
  * `allows` - `String`
  """
  @spec options(binary | list, binary) :: ast
  defmacro options(route, allows) do
    build_match :options, route, allows, __CALLER__
  end

  @doc """
  Macro for defining routes for custom HTTP methods.

  ## Arguments

  * `method` - `Atom`
  * `route` - `String|List`
  * `handler` - `Atom`
  * `action` - `Atom`
  """
  @spec raw(atom, binary | list, atom, atom) :: ast
  defmacro raw(method, route, handler, action) do
    build_match method, route, handler, action, __CALLER__
  end

  @doc """
  Creates RESTful resource endpoints for a route/handler
  combination.

  ## Example

      resource :users, Handlers.User

  expands to

      get,     "/users",      Handlers.User, :index
      post,    "/users",      Handlers.User, :create
      get,     "/users/:id",  Handlers.User, :show
      put,     "/users/:id",  Handlers.User, :update
      patch,   "/users/:id",  Handlers.User, :patch
      delete,  "/users/:id",  Handlers.User, :delete

      options, "/users",      "HEAD,GET,POST"
      options, "/users/:_id", "HEAD,GET,PUT,PATCH,DELETE"
  """
  @spec resource(atom, atom, Keyword.t) :: [ast]
  defmacro resource(resource, handler, opts \\ []) do
    arg     = Keyword.get opts, :arg, :id
    allowed = Keyword.get opts, :only, [ :index, :create, :show,
                                         :update, :patch, :delete ]
    # mainly used by `version/2`
    prepend_path = Keyword.get opts, :prepend_path, nil
    if prepend_path, do: prepend_path = "/" <> prepend_path <> "/"

    routes  =
      [ { :get,     "#{prepend_path}#{resource}",          :index },
        { :post,    "#{prepend_path}#{resource}",          :create },
        { :get,     "#{prepend_path}#{resource}/:#{arg}",  :show },
        { :put,     "#{prepend_path}#{resource}/:#{arg}",  :update },
        { :patch,   "#{prepend_path}#{resource}/:#{arg}",  :patch },
        { :delete,  "#{prepend_path}#{resource}/:#{arg}",  :delete } ]

    options_routes =
      [ { "/#{ignore_args prepend_path}#{resource}",          [ index: :get, create: :post ] },
        { "/#{ignore_args prepend_path}#{resource}/:_#{arg}", [ show: :get, update: :put,
                                                                patch: :patch, delete: :delete ] } ]

    for { method, path, action } <- routes |> filter(allowed) do
      build_match method, path, handler, action, __CALLER__
    end ++ for { path, methods } <- options_routes do
      allows = methods
                |> filter(allowed)
                |> Enum.map(fn { _, m } ->
                  normalize_method(m)
                end)
                |> Enum.join(",")
      build_match :options, path, "HEAD,#{allows}", __CALLER__
    end
  end

  @doc """
  Macro for defining a version for a set of routes.

  ## Arguments

  * `version` - `String`
  """
  @spec version(binary, any) :: ast | [ast]
  defmacro version(version, do: body) do
    body = update_body_with_version body, version
    quote do
      unquote(body)
    end
  end

  ## Private API

  defp ignore_args(nil), do: ""
  defp ignore_args(str) do
    str
      |> String.to_char_list
      |> do_ignore_args
      |> to_string
  end

  defp do_ignore_args([]), do: []
  defp do_ignore_args([?:|t]), do: [?:,?_] ++ do_ignore_args(t)
  defp do_ignore_args([h|t]), do: [h] ++ do_ignore_args(t)

  defp update_body_with_version({ :__block__, [], calls }, version) do
    { :__block__, [], calls |> Enum.map(&prepend_version(&1, "/" <> version)) }
  end
  defp update_body_with_version(item, version) when is_tuple(item) do
    { :__block__, [], [item] |> Enum.map(&prepend_version(&1, "/" <> version)) }
  end

  defp prepend_version({ method, line, args }, version) do
    new_args = case method do
      :options ->
        [path, allows] = args
        [version <> path, allows]
      :raw ->
        [verb, path, handler, action] = args
        [verb, version <> path, handler, action]
      :resource ->
        case args do
          [resource, handler] ->
            [resource, handler, [prepend_path: version]]
          [resource, handler, opts] ->
            opts = Keyword.update opts, :prepend_path, version, &("#{version}/#{&1}")
            [resource, handler, opts]
        end
      _ ->
        [path, handler, action] = args
        [version <> path, handler, action]
    end
    { method, line, new_args }
  end

  # Builds a `do_match/2` function body for a given route.
  defp build_match(:options, route, allows, caller) do
    body = quote do
        conn
          |> Plug.Conn.resp(200, "")
          |> Plug.Conn.put_resp_header("allow", unquote(allows))
          |> Plug.Conn.send_resp
      end

    do_build_match :options, route, body, caller
  end
  defp build_match(method, route, handler, action, caller) do
    body = build_body handler, action, caller
    # body_json = build_body handler, action, caller, :json
    # body_xml = build_body handler, action, caller, :xml

    [ #do_build_match(method, route <> ".json", body_json, caller),
      #do_build_match(method, route <> ".xml", body_xml, caller),
      do_build_match(method, route, body, caller) ]
  end

  defp do_build_match(verb, route, body, caller) do
    { method, guards, _vars, match } = prep_match verb, route, caller
    method = if verb == :any, do: quote(do: _), else: method

    quote do
      def do_match(unquote(method), unquote(match)) when unquote(guards) do
        fn conn ->
          unquote(body)
        end
      end
    end
  end

  defp build_body(handler, action, caller), do: build_body(handler, action, caller, :skip)
  defp build_body(handler, action, _caller, add_header) do
    header = case add_header do
        :json -> [{"accept", "application/json"}]
        :xml  -> [{"accept", "application/xml"}]
        _     -> []
      end

    quote do
      opts = [ action: unquote(action), args: binding() ]
      private = conn.private
                  |> Map.put(:controller, unquote(handler))
                  |> Map.put(:handler, unquote(handler))
                  |> Map.put(:action, unquote(action))

      %{ conn | req_headers: unquote(header) ++ conn.req_headers,
                private: private }
        |> unquote(handler).call(unquote(handler).init(opts))
    end
  end

  defp filter(list, allowed) do
    Enum.filter list, &do_filter(&1, allowed)
  end

  defp do_filter({ _, _, action }, allowed) do
    action in allowed
  end
  defp do_filter({ action, _ }, allowed) do
    action in allowed
  end

  ## Grabbed from `Plug.Router`

  defp prep_match(method, route, caller) do
    { method, guard } = method |> List.wrap |> convert_methods
    { path, guards }  = extract_path_and_guards(route, guard)
    { vars, match }   = path |> Macro.expand(caller) |> build_spec
    { method, guards, vars, match }
  end

  # Convert the verbs given with :via into a variable
  # and guard set that can be added to the dispatch clause.
  defp convert_methods([]) do
    { quote(do: _), true }
  end
  defp convert_methods([method]) do
    { normalize_method(method), true }
  end

  # Extract the path and guards from the path.
  defp extract_path_and_guards({ :when, _, [ path, guards ] }, true) do
    { path, guards }
  end
  defp extract_path_and_guards({ :when, _, [ path, guards ] }, extra_guard) do
    { path, { :and, [], [ guards, extra_guard ] } }
  end
  defp extract_path_and_guards(path, extra_guard) do
    { path, extra_guard }
  end
end
