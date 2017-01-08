# Miasma Terraform

Terraform API plugin for the miasma cloud library

## Supported credential attributes:

Supported attributes used in the credentials section of API
configurations:

```ruby
Miasma.api(
  :type => :orchestration,
  :provider => :terraform,
  :credentials => {
    ...
  }
)
```

### Common attributes

* `terraform_driver` - Interface to use (`atlas`, `boule`, `local`)

### Atlas attributes

```ruby
Miasma.api(
  :type => :orchestration,
  :provider => :terraform,
  :credentials => {
    :terraform_driver => :atlas
    ...
  }
)
```

* `terraform_atlas_endpoint` - Atlas URL
* `terraform_atlas_token` - Atlas token

### Boule attributes

```ruby
Miasma.api(
  :type => :orchestration,
  :provider => :terraform,
  :credentials => {
    :terraform_driver => :boule
    ...
  }
)
```

* `terraform_boule_endpoint` - Boule URL

### Local attributes

```ruby
Miasma.api(
  :type => :orchestration,
  :provider => :terraform,
  :credentials => {
    :terraform_driver => :local
    ...
  }
)
```

* `terraform_local_directory` - Path to store stack data
* `terraform_local_scrub_destroyed` - Delete stack data directory on destroy

## Current support matrix

|Model         |Create|Read|Update|Delete|
|--------------|------|----|------|------|
|AutoScale     |      |    |      |      |
|BlockStorage  |      |    |      |      |
|Compute       |      |    |      |      |
|DNS           |      |    |      |      |
|LoadBalancer  |      |    |      |      |
|Network       |      |    |      |      |
|Orchestration |  X   | X  |  X   |  X   |
|Queues        |      |    |      |      |
|Storage       |      |    |      |      |

## Info
* Repository: https://github.com/miasma-rb/miasma-terraform
