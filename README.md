# Quick Apply Guide - Local Files Only

Simple steps to apply your ACM policy from local files (no GitOps needed).

## Step 1: Edit generate-config.yaml with your values.

```bash
vim generate-config.yaml
```

## Step 2: Generate Your Policy

```bash
./generate-acm-policy.sh -c generate-config.yaml
```

This creates a directory like `acm-policy-<name>-policy/` with all the files.

## Step 3: Apply to ACM Cluster

# Apply the processed resources (Policy, Placement, PlacementBinding)
```
oc apply -f acm-policy-<name>-policy/processed-resources.yaml
```

## What Happens?

1. The script generates a `PolicyGenerator` resource
2. The script automatically processes it to create:
   - **Policy**: The actual policy with your manifests embedded
   - **Placement**: Defines which clusters get the policy (using cluster sets or selectors)
   - **PlacementBinding**: Links the Policy to the Placement (always included)
3. You apply the processed resources directly to your cluster

## Complete generate

```bash
# 1. Generate and process
./generate-acm-policy.sh -c generate-config.yaml

# 2. Apply (using helper script)
./apply-policy.sh acm-policy-chrony-policy

# OR apply manually
oc apply -f acm-policy-chrony-policy/processed-resources.yaml

# 3. Verify
oc get policy -n day2
oc get placement -n day2
oc get policy chrony-policy -n day2 -o yaml
```

That's it! No GitOps needed - just local files and `oc apply`.

