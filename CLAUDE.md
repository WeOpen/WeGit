# WeGit contributor guidance

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for the Issue, branch, PR and release workflow. Keep personal repositories, configuration, credentials and system settings isolated from automated checks. Record actual test execution and its limits; a successful build does not establish UI or release acceptance.

## Skill routing

When the user's request matches an available skill, invoke that skill and follow its `SKILL.md`. When in doubt, invoke the relevant skill.

Key routing rules:

- Product ideas and brainstorming → `/office-hours`
- Strategy and scope → `/plan-ceo-review`
- Architecture → `/plan-eng-review`
- Design systems and plan review → `/design-consultation` or `/plan-design-review`
- Full review pipeline → `/autoplan`
- Bugs and errors → `/investigate`
- QA and site behavior → `/qa` or `/qa-only`
- Code review and diff checks → `/review`
- Visual polish → `/design-review`
- Shipping, deployment and PRs → `/ship` or `/land-and-deploy`
- Save progress → `/context-save`
- Resume context → `/context-restore`
- Backlog specifications and Issues → `/spec`
