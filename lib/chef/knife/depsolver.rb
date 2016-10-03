require 'chef/knife'

class Chef
  class Knife
    class Depsolver < Knife
      deps do
      end

      banner 'knife depsolver RUN_LIST'

      option :node,
             short: '-n',
             long: '--node NAME',
             description: 'Use the run list from a given node'

      option :local_depsolver,
             long: '--local-depsolver',
             description: 'Use the local depsolver'

      option :timeout,
             short: '-t',
             long: '--timeout SECONDS',
             description: 'Set the local depsolver timeout. Only valid when using the --local-depsolver option'

      def run
        begin
          use_local_depsolver = config[:local_depsolver]
          timeout = 5000
          if config[:timeout]
            if use_local_depsolver
              timeout = (config[:timeout].to_f * 1000).to_i
            else
              msg("ERROR: The --timeout option is only compatible with the --local-depsolver option")
              exit!
            end
          end

          if config[:node]
            node = Chef::Node.load(config[:node])
          else
            node = Chef::Node.new
            node.name('depsolver-tmp-node')

            run_list = name_args.map {|item| item.to_s.split(/,/) }.flatten.each{|item| item.strip! }
            run_list.delete_if {|item| item.empty? }

            run_list.each do |arg|
              node.run_list.add(arg)
            end
          end

          node.chef_environment = config[:environment] if config[:environment]

          environment_cookbook_versions = Chef::Environment.load(environment).cookbook_versions

          if use_local_depsolver
            env_ckbk_constraints = environment_cookbook_versions.map do |ckbk_name, ckbk_constraint|
              [ckbk_name, ckbk_constraint.split.reverse].flatten
            end

            universe = rest.get_rest("universe")

            all_versions = universe.map do |ckbk_name, ckbk_metadata|
              ckbk_versions = ckbk_metadata.map do |version, version_metadata|
                [version, version_metadata['dependencies'].map { |dep_ckbk_name, dep_ckbk_constraint| [dep_ckbk_name, dep_ckbk_constraint.split.reverse].flatten }]
              end
              [ckbk_name, ckbk_versions]
            end
          end

          run_list_expansion = node.run_list.expand(node.chef_environment, 'server')
          expanded_run_list_with_versions = run_list_expansion.recipes.with_version_constraints_strings

          depsolver_results = Hash.new
          if use_local_depsolver
            expanded_run_list_with_split_versions = expanded_run_list_with_versions.map do |run_list_item|
              name, version = run_list_item.split('@')
              name.sub!(/::.*/, '')
              version ? [name, version] : name
            end

            data = {environment_constraints: env_ckbk_constraints, all_versions: all_versions, run_list: expanded_run_list_with_split_versions, timeout_ms: timeout}

            depsolver_start_time = Time.now

            solution = solve(data)

            depsolver_finish_time = Time.now

            if solution.first == :ok
              solution.last.map { |ckbk| ckbk_name, ckbk_version = ckbk; depsolver_results[ckbk_name] = ckbk_version.join('.') }
            else
              status, error_type, error_detail = solution
              depsolver_error = { error_type => error_detail }
            end
          else
            depsolver_start_time = Time.now

            ckbks = rest.post_rest("environments/" + node.chef_environment + "/cookbook_versions", { "run_list" => expanded_run_list_with_versions })

            depsolver_finish_time = Time.now

            ckbks.each do |name, ckbk|
              version = ckbk.is_a?(Hash) ? ckbk['version'] : ckbk.version
              depsolver_results[name] = version
            end
          end
        rescue Net::HTTPServerException => e
          api_error = {}
          api_error[:error_code] = e.response.code
          api_error[:error_message] = e.response.message
          begin
            api_error[:error_body] = JSON.parse(e.response.body)
          rescue JSON::ParserError
          end
        rescue => e
          msg("ERROR: #{e.message}")
          exit!
        ensure
          results = {}
          results[:node] = node.name unless node.nil? || node.name.nil?
          results[:environment] = node.chef_environment unless node.chef_environment.nil?
          results[:environment_cookbook_versions] = environment_cookbook_versions unless environment_cookbook_versions.nil?
          results[:run_list] = node.run_list unless node.nil? || node.run_list.nil?
          results[:expanded_run_list] = expanded_run_list_with_versions unless expanded_run_list_with_versions.nil?
          results[:depsolver_results] = depsolver_results unless depsolver_results.nil? || depsolver_results.empty?
          results[:depsolver_cookbook_count] = depsolver_results.count unless depsolver_results.nil? || depsolver_results.empty?
          results[:depsolver_elapsed_ms] = ((depsolver_finish_time - depsolver_start_time) * 1000).to_i unless depsolver_finish_time.nil?
          results[:depsolver_error] = depsolver_error unless depsolver_error.nil?
          results[:api_error] = api_error unless api_error.nil?

          msg(JSON.pretty_generate(results))
        end
      end
    end
  end
end
