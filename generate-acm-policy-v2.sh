#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] | -c <config-file>

Generate and process ACM (Advanced Cluster Management) Policy from YAML files.
This script generates the PolicyGenerator, then processes it to create Policy, Placement, PlacementBinding, and ManagedClusterSetBinding resources (when using cluster sets).

Options:
  -c, --config FILE          Load configuration from YAML file (overrides CLI args)
  -n, --name NAME            Policy name (required if not using -c)
  -f, --files FILES          Comma-separated list of YAML files to include (required if not using -c)
  -s, --selectors SELECTORS  Comma-separated cluster selectors (key=value) (required if not using -c or clusterSets)
  --clustersets SETS         Comma-separated cluster set names (alternative to selectors)
  -ns, --namespace NS        Namespace for the policy (default: policies)
  -r, --remediation ACTION   Remediation action: enforce or inform (default: enforce)
  -o, --output DIR           Output directory name (default: acm-policy-<name>)
  -p, --process              Process PolicyGenerator to create Policy/Placement/ManagedClusterSetBinding (default: true)
  -h, --help                 Show this help message

Config File Format (YAML):
  policyName: <policy-name>
  namespace: <namespace>
  remediationAction: <enforce|inform>
  complianceType: <musthave|mustnothave>  # optional
  pruneObjectBehavior: <none|DeleteAll|DeleteIfCreated>  # optional
  files:
    - <path-to-yaml-file1>
    - <path-to-yaml-file2>
  # Option 1: Use cluster selectors
  clusterSelectors:
    <key1>: <value1>
    <key2>: <value2>
  # Option 2: Use cluster sets (requires ManagedClusterSetBinding for each set)
  clusterSets:
    - <cluster-set-name1>
    - <cluster-set-name2>
  # Note: When using cluster sets, ManagedClusterSetBinding resources are automatically created.
  # Optional: Placement labels for matchExpressions (works with cluster sets)
  placementLabels:
    - key: environment
      operator: In
      values: ["dev"]
    # Or use simple format:
    # - environment: ["dev", "test"]
  outputDir: <output-directory>  # optional
  processPolicyGenerator: <true|false>  # optional, default: true

Examples:
  # Using command-line arguments:
  $0 -n my-policy -f file1.yaml,file2.yaml -s environment=prod,region=us-east

  # Using config file:
  $0 -c config.yaml

Reference: https://github.com/redfrax/post-gitops-rhacm-kustomize-polgen
EOF
    exit 1
}

# Default values
NAMESPACE="policies"
REMEDIATION="enforce"
POLICY_NAME=""
FILES=""
SELECTORS=""
CLUSTER_SETS=""
CONFIG_FILE=""
OUTPUT_DIR=""
PROCESS_POLICYGEN=true
COMPLIANCE_TYPE=""
PRUNE_OBJECT_BEHAVIOR=""
PLACEMENT_LABELS_FILE=""

# Check if required tools are available
check_dependencies() {
    local missing_tools=()
    
    if ! command -v python3 &> /dev/null; then
        missing_tools+=("python3")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required tools: ${missing_tools[*]}${NC}"
        echo "Please install missing tools and try again."
        exit 1
    fi
    
    # Check for PyYAML
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo -e "${RED}Error: Python PyYAML module not found${NC}"
        echo "Please install it with: pip install pyyaml"
        exit 1
    fi
}

# Parse YAML config file
parse_config_file() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Config file not found: $config_file${NC}"
        exit 1
    fi
    
    # Use python3 to parse config
    local config_data=$(python3 <<PYEOF
import yaml
import sys

try:
    with open('$config_file', 'r') as f:
        config = yaml.safe_load(f)
    
    print(f"POLICY_NAME={config.get('policyName', '')}")
    print(f"NAMESPACE={config.get('namespace', 'policies')}")
    print(f"REMEDIATION={config.get('remediationAction', 'enforce')}")
    print(f"OUTPUT_DIR={config.get('outputDir', '')}")
    print(f"PROCESS_POLICYGEN={str(config.get('processPolicyGenerator', True)).lower()}")
    print(f"COMPLIANCE_TYPE={config.get('complianceType', '')}")
    print(f"PRUNE_OBJECT_BEHAVIOR={config.get('pruneObjectBehavior', '')}")
    
    files = config.get('files', [])
    if files:
        print(f"FILES={','.join(files)}")
    
    selectors = config.get('clusterSelectors', {})
    if selectors:
        sel_pairs = [f"{k}={v}" for k, v in selectors.items()]
        print(f"SELECTORS={','.join(sel_pairs)}")
    
    cluster_sets = config.get('clusterSets', [])
    if cluster_sets:
        print(f"CLUSTER_SETS={','.join(cluster_sets)}")
    
    # Handle placementLabels - write to temp file for Python processing
    import tempfile
    import json
    import os
    placement_labels = config.get('placementLabels', [])
    if placement_labels:
        temp_file = tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json')
        json.dump(placement_labels, temp_file)
        temp_file.close()
        print(f"PLACEMENT_LABELS_FILE={temp_file.name}")
except Exception as e:
    print(f"Error parsing config: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    )
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to parse config file${NC}"
        exit 1
    fi
    
    eval "$config_data"
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -n|--name)
                POLICY_NAME="$2"
                shift 2
                ;;
            -f|--files)
                FILES="$2"
                shift 2
                ;;
            -s|--selectors)
                SELECTORS="$2"
                shift 2
                ;;
            --clustersets)
                CLUSTER_SETS="$2"
                shift 2
                ;;
            -ns|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--remediation)
                REMEDIATION="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -p|--process)
                PROCESS_POLICYGEN=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Error: Unknown option: $1${NC}"
                usage
                ;;
        esac
    done
}

# Validate inputs
validate_inputs() {
    local errors=()
    
    if [ -z "$POLICY_NAME" ]; then
        errors+=("Policy name is required")
    fi
    
    if [ -z "$FILES" ]; then
        errors+=("At least one YAML file is required")
    fi
    
    if [ -z "$SELECTORS" ] && [ -z "$CLUSTER_SETS" ]; then
        errors+=("Either cluster selectors or cluster sets are required")
    fi
    
    if [ -n "$SELECTORS" ] && [ -n "$CLUSTER_SETS" ]; then
        errors+=("Cannot use both cluster selectors and cluster sets. Choose one.")
    fi
    
    if [ "$REMEDIATION" != "enforce" ] && [ "$REMEDIATION" != "inform" ]; then
        errors+=("Remediation action must be 'enforce' or 'inform'")
    fi
    
    if [ -n "$COMPLIANCE_TYPE" ] && [ "$COMPLIANCE_TYPE" != "musthave" ] && [ "$COMPLIANCE_TYPE" != "mustnothave" ]; then
        errors+=("Compliance type must be 'musthave' or 'mustnothave'")
    fi
    
    if [ -n "$PRUNE_OBJECT_BEHAVIOR" ] && [ "$PRUNE_OBJECT_BEHAVIOR" != "none" ] && [ "$PRUNE_OBJECT_BEHAVIOR" != "DeleteAll" ] && [ "$PRUNE_OBJECT_BEHAVIOR" != "DeleteIfCreated" ]; then
        errors+=("Prune object behavior must be 'none', 'DeleteAll', or 'DeleteIfCreated'")
    fi
    
    if [ ${#errors[@]} -gt 0 ]; then
        echo -e "${RED}Validation errors:${NC}"
        for error in "${errors[@]}"; do
            echo -e "  ${RED}•${NC} $error"
        done
        exit 1
    fi
}

# Process PolicyGenerator to create Policy, Placement, and ManagedClusterSetBinding
process_policygenerator() {
    local policy_dir="$1"
    local policygen_file="$policy_dir/policygenerator.yaml"
    local output_file="$policy_dir/processed-resources.yaml"
    
    python3 <<PYEOF
import yaml
import sys
import os
import glob

try:
    # Read PolicyGenerator
    with open('$policygen_file', 'r') as f:
        policygen = yaml.safe_load(f)

    # Extract values
    policy_name = policygen['policies'][0]['name']
    namespace = policygen.get('policyDefaults', {}).get('namespace', 'policies')
    remediation = policygen.get('policyDefaults', {}).get('remediationAction', 'enforce')
    placement = policygen.get('placement', [{}])[0]
    placement_name = placement.get('name', f"placement-{policy_name}")
    cluster_selectors = placement.get('clusterSelectors', {})
    cluster_sets = placement.get('clusterSets', [])
    
    # Also check environment variable if passed from parent script
    import os
    import json
    env_cluster_sets = os.environ.get('CLUSTER_SETS_FOR_PROCESSING', '')
    if env_cluster_sets and not cluster_sets:
        cluster_sets = [s.strip() for s in env_cluster_sets.split(',') if s.strip()]
    
    # Get pruneObjectBehavior from environment variable if passed from parent script
    prune_object_behavior = os.environ.get('PRUNE_OBJECT_BEHAVIOR', '')
    
    # Get placement labels from file if passed from parent script
    placement_labels = []
    placement_labels_file = os.environ.get('PLACEMENT_LABELS_FILE', '')
    if placement_labels_file and os.path.exists(placement_labels_file):
        with open(placement_labels_file, 'r') as f:
            placement_labels = json.load(f)
        # Clean up temp file
        try:
            os.unlink(placement_labels_file)
        except:
            pass

    # Read manifest files
    manifests_dir = '$policy_dir/manifests'
    manifest_files = sorted(glob.glob(os.path.join(manifests_dir, '*.yaml')) + 
                            glob.glob(os.path.join(manifests_dir, '*.yml')))

    if not manifest_files:
        print("Error: No manifest files found", file=sys.stderr)
        sys.exit(1)

    print(f"📋 Processing {len(manifest_files)} manifest files...")
    for f in manifest_files:
        print(f"  ✓ {os.path.basename(f)}")

    # Read manifest contents
    manifest_objects = []
    for file_path in manifest_files:
        with open(file_path, 'r') as f:
            manifest_objects.append(yaml.safe_load(f))

    # Generate Policy with properly formatted object-templates
    # Build object-templates list
    object_templates = []
    for obj in manifest_objects:
        template = {
            'complianceType': 'musthave',
            'objectDefinition': obj
        }
        # Add pruneObjectBehavior if specified
        if prune_object_behavior:
            template['pruneObjectBehavior'] = prune_object_behavior
        object_templates.append(template)

    # Build the full policy structure
    # Note: Placement is referenced directly in Policy spec (PlacementBinding is deprecated)
    policy = {
        'apiVersion': 'policy.open-cluster-management.io/v1',
        'kind': 'Policy',
        'metadata': {
            'name': policy_name,
            'namespace': namespace
        },
        'spec': {
            'remediationAction': remediation,
            'disabled': False,
            'policy-templates': [{
                'objectDefinition': {
                    'apiVersion': 'policy.open-cluster-management.io/v1',
                    'kind': 'ConfigurationPolicy',
                    'metadata': {
                        'name': policy_name
                    },
                    'spec': {
                        'remediationAction': remediation,
                        'severity': 'low',
                        'object-templates': object_templates
                    }
                }
            }]
        }
    }

    # Generate ManagedClusterSetBinding and Placement
    resources = []
    
    if cluster_sets:
        # Use cluster sets - need ManagedClusterSetBinding for each cluster set
        for cluster_set in cluster_sets:
            managed_cluster_set_binding = {
                'apiVersion': 'cluster.open-cluster-management.io/v1beta2',
                'kind': 'ManagedClusterSetBinding',
                'metadata': {
                    'name': cluster_set,
                    'namespace': namespace
                },
                'spec': {
                    'clusterSet': cluster_set
                }
            }
            resources.append(managed_cluster_set_binding)
        
        # Generate Placement with cluster sets
        placement_spec = {
            'clusterSets': cluster_sets
        }
        
        # Add predicates if we have placement labels
        if placement_labels:
            match_expressions = []
            for label in placement_labels:
                # Support both simple format {key: values} and full format {key, operator, values}
                if isinstance(label, dict):
                    if 'key' in label:
                        # Full format: {key: "env", operator: "In", values: ["dev"]}
                        match_expressions.append({
                            'key': label.get('key'),
                            'operator': label.get('operator', 'In'),
                            'values': label.get('values', [])
                        })
                    else:
                        # Simple format: {environment: ["dev"]} - convert to matchExpression
                        for key, values in label.items():
                            match_expressions.append({
                                'key': key,
                                'operator': 'In',
                                'values': values if isinstance(values, list) else [values]
                            })
            
            if match_expressions:
                placement_spec['predicates'] = [{
                    'requiredClusterSelector': {
                        'labelSelector': {
                            'matchExpressions': match_expressions
                        }
                    }
                }]
        
        placement_resource = {
            'apiVersion': 'cluster.open-cluster-management.io/v1beta1',
            'kind': 'Placement',
            'metadata': {
                'name': placement_name,
                'namespace': namespace
            },
            'spec': placement_spec
        }
        resources.append(placement_resource)
        
        # Generate PlacementBinding to bind Policy to Placement
        binding_name = f"binding-{policy_name}"
        binding = {
            'apiVersion': 'policy.open-cluster-management.io/v1',
            'kind': 'PlacementBinding',
            'metadata': {
                'name': binding_name,
                'namespace': namespace
            },
            'placementRef': {
                'name': placement_name,
                'kind': 'Placement',
                'apiGroup': 'cluster.open-cluster-management.io'
            },
            'subjects': [{
                'name': policy_name,
                'kind': 'Policy',
                'apiGroup': 'policy.open-cluster-management.io'
            }]
        }
        resources.append(binding)
        
        # Reference Placement and PlacementBinding in Policy spec
        policy['spec']['placement'] = [{
            'placement': placement_name,
            'placementBinding': binding_name
        }]
    else:
        # Use cluster selectors
        match_labels = {}
        for k, v in cluster_selectors.items():
            match_labels[k] = v

        # Use cluster selectors - no ManagedClusterSetBinding needed
        placement_resource = {
            'apiVersion': 'cluster.open-cluster-management.io/v1beta1',
            'kind': 'Placement',
            'metadata': {
                'name': placement_name,
                'namespace': namespace
            },
            'spec': {
                'clusterSets': [],
                'numberOfClusters': None,
                'predicates': [{
                    'requiredClusterSelector': {
                        'labelSelector': {
                            'matchLabels': match_labels
                        }
                    }
                }]
            }
        }
        resources.append(placement_resource)
        
        # Generate PlacementBinding to bind Policy to Placement
        binding_name = f"binding-{policy_name}"
        binding = {
            'apiVersion': 'policy.open-cluster-management.io/v1',
            'kind': 'PlacementBinding',
            'metadata': {
                'name': binding_name,
                'namespace': namespace
            },
            'placementRef': {
                'name': placement_name,
                'kind': 'Placement',
                'apiGroup': 'cluster.open-cluster-management.io'
            },
            'subjects': [{
                'name': policy_name,
                'kind': 'Policy',
                'apiGroup': 'policy.open-cluster-management.io'
            }]
        }
        resources.append(binding)
        
        # Reference Placement and PlacementBinding in Policy spec
        policy['spec']['placement'] = [{
            'placement': placement_name,
            'placementBinding': binding_name
        }]

    # Build final resources list: Policy first, then ManagedClusterSetBindings (if any), 
    # then Placement, then PlacementBinding
    resources = [policy] + resources

    # Write all resources with proper YAML formatting
    from yaml import SafeDumper
    
    # Custom representer for None values
    def represent_none(self, _):
        return self.represent_scalar('tag:yaml.org,2002:null', '')
    
    SafeDumper.add_representer(type(None), represent_none)
    
    with open('$output_file', 'w') as f:
        for i, resource in enumerate(resources):
            yaml.dump(resource, f, Dumper=SafeDumper, default_flow_style=False, 
                     sort_keys=False, allow_unicode=True, width=1000)
            if i < len(resources) - 1:
                f.write('---\n')

    print('$output_file')
except Exception as e:
    import traceback
    print(f"Error: {e}", file=sys.stderr)
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Generate PolicyGenerator YAML
generate_policygenerator() {
    local workdir="$1"
    local manifests_dir="$2"
    
    # Convert cluster selectors to YAML
    local SELECTOR_YAML=""
    if [ -n "$SELECTORS" ]; then
        IFS=',' read -ra SEL_ARRAY <<< "$SELECTORS"
        for s in "${SEL_ARRAY[@]}"; do
            s=$(echo "$s" | xargs) # trim whitespace
            KEY="${s%%=*}"
            VAL="${s#*=}"
            if [ -z "$KEY" ] || [ -z "$VAL" ]; then
                echo -e "${RED}❌ Error: Invalid selector format: $s (expected key=value)${NC}"
                exit 1
            fi
            SELECTOR_YAML+="      $KEY: $VAL"$'\n'
        done
        SELECTOR_YAML="${SELECTOR_YAML%$'\n'}"
    fi
    
    # Build placement section
    local PLACEMENT_SECTION=""
    if [ -n "$CLUSTER_SETS" ]; then
        # Use cluster sets
        local CLUSTER_SETS_YAML=""
        IFS=',' read -ra SETS_ARRAY <<< "$CLUSTER_SETS"
        for s in "${SETS_ARRAY[@]}"; do
            s=$(echo "$s" | xargs) # trim whitespace
            CLUSTER_SETS_YAML+="      - $s"$'\n'
        done
        CLUSTER_SETS_YAML="${CLUSTER_SETS_YAML%$'\n'}"
        
        PLACEMENT_SECTION="placement:
  - name: placement-${POLICY_NAME}
    clusterSets:
${CLUSTER_SETS_YAML}"
    elif [ -n "$SELECTOR_YAML" ]; then
        # Use cluster selectors
        PLACEMENT_SECTION="placement:
  - name: placement-${POLICY_NAME}
    clusterSelectors:
${SELECTOR_YAML}"
    fi
    
    # Build compliance type section
    local COMPLIANCE_SECTION=""
    if [ -n "$COMPLIANCE_TYPE" ]; then
        COMPLIANCE_SECTION="    complianceType: ${COMPLIANCE_TYPE}"
    fi
    
    echo -e "${BLUE}📝 Creating PolicyGenerator file...${NC}"
    cat > "$workdir/policygenerator.yaml" <<EOF
apiVersion: policy.open-cluster-management.io/v1
kind: PolicyGenerator
metadata:
  name: ${POLICY_NAME}
policyDefaults:
  namespace: ${NAMESPACE}
  remediationAction: ${REMEDIATION}
policies:
  - name: ${POLICY_NAME}
    manifests:
      - path: ${manifests_dir}
${COMPLIANCE_SECTION}
${PLACEMENT_SECTION}
EOF
}

# Main execution
main() {
    check_dependencies
    
    parse_args "$@"
    
    # Load config file if provided
    if [ -n "$CONFIG_FILE" ]; then
        echo -e "${BLUE}📄 Loading configuration from: $CONFIG_FILE${NC}"
        parse_config_file "$CONFIG_FILE"
    fi
    
    validate_inputs
    
    # Set output directory
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="acm-policy-${POLICY_NAME}"
    fi
    
    WORKDIR="$OUTPUT_DIR"
    
    echo -e "${BLUE}📁 Creating work directory: $WORKDIR${NC}"
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR/manifests"
    
    # Copy YAML files
    echo -e "${BLUE}📋 Copying YAML files...${NC}"
    IFS=',' read -ra FILE_ARRAY <<< "$FILES"
    local copied_count=0
    for f in "${FILE_ARRAY[@]}"; do
        f=$(echo "$f" | xargs) # trim whitespace
        if [ ! -f "$f" ]; then
            echo -e "${RED}❌ Error: File not found: $f${NC}"
            exit 1
        fi
        local filename=$(basename "$f")
        cp "$f" "$WORKDIR/manifests/$filename"
        echo -e "  ${GREEN}✓${NC} $f -> manifests/$filename"
        ((copied_count++))
    done
    
    if [ $copied_count -eq 0 ]; then
        echo -e "${RED}❌ Error: No files were copied${NC}"
        exit 1
    fi
    
    # Generate PolicyGenerator
    generate_policygenerator "$WORKDIR" "manifests"
    
    # Create kustomization.yaml
    echo -e "${BLUE}🛠 Creating kustomization.yaml...${NC}"
    cat > "$WORKDIR/kustomization.yaml" <<EOF
resources:
  - policygenerator.yaml
EOF
    
    # Process PolicyGenerator if requested
    if [ "$PROCESS_POLICYGEN" = "true" ]; then
        echo -e "${BLUE}🔄 Processing PolicyGenerator to create Policy resources...${NC}"
        # Pass cluster sets, pruneObjectBehavior, and placement labels info to processing function
        export CLUSTER_SETS_FOR_PROCESSING="$CLUSTER_SETS"
        export PRUNE_OBJECT_BEHAVIOR="$PRUNE_OBJECT_BEHAVIOR"
        export PLACEMENT_LABELS_FILE="$PLACEMENT_LABELS_FILE"
        local output_file=$(process_policygenerator "$WORKDIR" 2>&1)
        local exit_code=$?
        
        if [ $exit_code -ne 0 ] || [[ "$output_file" == *"Error:"* ]]; then
            echo -e "${RED}❌ Error: Failed to process PolicyGenerator${NC}"
            echo "$output_file" | grep -v "^📋" | grep -v "^  ✓" || echo "$output_file"
            exit 1
        fi
        
        # Extract just the filename from output
        local processed_file=$(echo "$output_file" | tail -1)
        if [ -f "$processed_file" ]; then
            echo -e "${GREEN}✅ Successfully processed PolicyGenerator!${NC}"
            echo -e "${GREEN}   Processed resources: $processed_file${NC}"
            if [ -n "$CLUSTER_SETS" ]; then
                echo -e "${BLUE}   Note: Using cluster sets (ManagedClusterSetBinding resources included)${NC}"
            fi
        fi
    else
        echo -e "${BLUE}🚀 Running kustomize to generate final policy...${NC}"
        if ! kustomize build "$WORKDIR" > "$WORKDIR/final-policy.yaml" 2>&1; then
            echo -e "${RED}❌ Error: kustomize build failed${NC}"
            exit 1
        fi
    fi
    
    echo ""
    echo -e "${GREEN}✅ Successfully generated ACM policy!${NC}"
    echo -e "${GREEN}   Policy name: ${POLICY_NAME}${NC}"
    echo -e "${GREEN}   Namespace: ${NAMESPACE}${NC}"
    echo -e "${GREEN}   Remediation: ${REMEDIATION}${NC}"
    if [ -n "$COMPLIANCE_TYPE" ]; then
        echo -e "${GREEN}   Compliance type: ${COMPLIANCE_TYPE}${NC}"
    fi
    if [ -n "$PRUNE_OBJECT_BEHAVIOR" ]; then
        echo -e "${GREEN}   Prune object behavior: ${PRUNE_OBJECT_BEHAVIOR}${NC}"
    fi
    
    # Show which manifest files are included
    if [ -d "$WORKDIR/manifests" ]; then
        local manifest_files=$(find "$WORKDIR/manifests" -name "*.yaml" -o -name "*.yml" | sort)
        if [ -n "$manifest_files" ]; then
            echo -e "${BLUE}   Manifest files included:${NC}"
            while IFS= read -r file; do
                local filename=$(basename "$file")
                echo -e "     ${GREEN}•${NC} $filename"
            done <<< "$manifest_files"
        fi
    fi
    
    echo ""
    if [ "$PROCESS_POLICYGEN" = "true" ]; then
        echo -e "${BLUE}📋 Next step: Apply the processed resources${NC}"
        echo -e "   oc apply -f $WORKDIR/processed-resources.yaml"
    else
        echo -e "${BLUE}📋 Next step: Apply the PolicyGenerator${NC}"
        echo -e "   oc apply -f $WORKDIR/policygenerator.yaml"
    fi
}

# Run main function
main "$@"

