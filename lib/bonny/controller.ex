defmodule Bonny.Controller do
  @moduledoc """
  `Bonny.Controller` defines controller behaviours and generates boilerplate for generating Kubernetes manifests.

  > A custom controller is a controller that users can deploy and update on a running cluster, independently of the cluster’s own lifecycle. Custom controllers can work with any kind of resource, but they are especially effective when combined with custom resources. The Operator pattern is one example of such a combination. It allows developers to encode domain knowledge for specific applications into an extension of the Kubernetes API.

  Controllers allow for simple `add`, `modify`, `delete`, and `reconcile` handling of custom resources in the Kubernetes API.
  """

  @callback add(map()) :: :ok | :error
  @callback modify(map()) :: :ok | :error
  @callback delete(map()) :: :ok | :error
  @callback reconcile(map()) :: :ok | :error

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :rule, accumulate: true)
      @behaviour Bonny.Controller

      # CRD defaults
      @group Bonny.Config.group()
      @kind Bonny.Naming.module_to_kind(__MODULE__)
      @scope :namespaced
      @version Bonny.Naming.module_version(__MODULE__)

      @singular Macro.underscore(Bonny.Naming.module_to_kind(__MODULE__))
      @plural "#{@singular}s"
      @names %{}

      @additional_printer_columns []
      @before_compile Bonny.Controller
      
      use Supervisor
      def start_link(_) do
        Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)
      end

      @impl true
      def init(_init_arg) do
        children = [
          {__MODULE__.WatchServer, name: __MODULE__.WatchServer},
          {__MODULE__.ReconcileServer, name: __MODULE__.ReconcileServer}
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end         
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    controller = env.module
    
    quote bind_quoted: [controller: controller] do   
      defmodule WatchServer do
        use Bonny.Server.Watcher
        
        defdelegate add(resource), to: controller
        defdelegate modify(resource), to: controller
        defdelegate delete(resource), to: controller
        
        def watch_operation() do
          K8s.Client.list("v1", :pods)
        end
      end

      defmodule ReconcileServer do
        use Bonny.Server.Reconciler, frequency: 15
        defdelegate reconcile(resource), to: controller
        
        def reconcile_operation() do
          K8s.Client.list("v1", :pods)
        end
      end      
      
      @doc """
      Returns the `Bonny.CRD.t()` the controller manages the lifecycle of.
      """
      @spec crd() :: %Bonny.CRD{}
      def crd() do
        %Bonny.CRD{
          group: @group,
          scope: @scope,
          version: @version,
          names: Map.merge(default_names(), @names),
          additional_printer_columns: additional_printer_columns()
        }
      end

      @doc """
      A list of RBAC rules that this controller needs to operate.

      This list will be serialized into the operator manifest when using `mix bonny.gen.manifest`.
      """
      @spec rules() :: list(map())
      def rules() do
        Enum.reduce(@rule, [], fn {api, resources, verbs}, acc ->
          rule = %{
            apiGroups: [api],
            resources: resources,
            verbs: verbs
          }

          [rule | acc]
        end)
      end

      @spec default_names() :: map()
      defp default_names() do
        %{
          plural: @plural,
          singular: @singular,
          kind: @kind,
          shortNames: nil
        }
      end

      @spec additional_printer_columns() :: list(map())
      defp additional_printer_columns() do
        # this is how the default is getting included... could pass printer cols to CRD
        # and let CRD handle ([]) and that should solve dializer issue w/ @ being unused
        @additional_printer_columns ++ Bonny.CRD.default_columns()
      end
    end
  end
end
