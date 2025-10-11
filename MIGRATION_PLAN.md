# Migration Plan: From SSO Branch to Vanilla Campfire + Small Bets Mods

## Current State
- **Current Branch:** `feature/sso` - Contains OpenID Connect integration
- **Clean Branch:** `main` - Vanilla Once Campfire
- **Goal:** Start fresh with vanilla Campfire and add Small Bets modifications

---

## Step 1: Preserve SSO Branch

Your SSO work is safely committed on `feature/sso`. You can always return to it later.

```bash
# Verify SSO branch is committed
git checkout feature/sso
git status

# Tag it for easy reference (optional)
git tag sso-implementation-v1
git push origin sso-implementation-v1
```

---

## Step 2: Create New Development Branch

Start from vanilla Campfire (main branch):

```bash
# Switch to main
git checkout main

# Pull latest changes
git pull origin main

# Create new branch for modifications
git checkout -b feature/smallbets-mods
```

---

## Step 3: Add Small Bets Remote

```bash
# Add Small Bets repository as remote
git remote add smallbets https://github.com/antiwork/smallbets.git

# Fetch their branches
git fetch smallbets

# View their commits
git log smallbets/master --oneline | head -20
```

---

## Step 4: Recommended Feature Implementation Order

### Phase 1: Core UX Improvements (Week 1-2)
Start with features that improve basic user experience:

1. **User Counter**
   - Commit: `0a2c8bb92350f4199dd27719029db84cf1d0fcce`
   - Simple feature, shows room occupancy
   - Low risk, high value

2. **New Since Last Visit**
   - Commit: `efc8cc83c4ee55c34a95af7db125922109e3367f`
   - Helps users catch up
   - Visual marker for unread content

3. **Mark as Unread**
   - Commit: `ca728dc1c6e907e588f46fce397ca550e3c2199e`
   - User-requested feature
   - Improves workflow

### Phase 2: Enhanced Navigation (Week 3-4)

4. **Mentions Tab**
   - Commits: `d57db1930272978b36355aff8d28f56f9dfdd389`
   - Range: `f9b7ba3f..53d8b1e7`
   - Dedicated view for mentions
   - Major UX improvement

5. **Bookmarks**
   - Range: `975eb2f3..02999bd01`
   - Save important messages
   - New sidebar view

6. **Mentions List Relevance**
   - Commit: `56fed986542c8688dfab9b69a6eb8ae775599eb6`
   - Sort by recent activity
   - Better search experience

### Phase 3: Communication Features (Week 5-6)

7. **Replies as Mentions**
   - Commit: `7a3f2c87f1effd926d8841c7eeacd25f92b1ba95`
   - Treat replies like mentions
   - Better notification system

8. **Email Notifications**
   - Range: `b510fecf..9093dedd`
   - Email alerts for mentions/DMs
   - Critical for async communication

9. **One-click Reboost**
   - Commit: `bb871e05e5c42b5fde2bf655ba2b39f6111873b4`
   - Quick boost repetition
   - Small but useful

### Phase 4: Advanced Features (Week 7-8)

10. **Threads**
    - Multiple commits:
      - `7caa8de1da8c5fbc82db0d4f57bca168656bf774`
      - Range: `ddbc11f0..f2e768ea`
      - `45576812b9cdb5caef387790fe65910230eccb1f`
      - Range: `7333c40a..9ad6e5d0`
    - Message boards with 30-day auto-expiry
    - Complex feature, test thoroughly

11. **Block Pings**
    - Commit: `a4687e1bb9ad40871423d88323573e345ba68df4`
    - User safety feature
    - Admin monitoring

12. **Stats Page**
    - Activity leaderboards
    - Community engagement metrics

### Phase 5: Infrastructure (Week 9-10)

13. **Soft Deletion**
    - Commits:
      - `cd4fb3c71729e630018a636e94819e1a0ded6ad3`
      - `bda3f96f7fa9f7ad1cdc82add617851dcf95a26c`
    - Non-destructive deletes
    - Important for data safety
    - **IMPORTANT:** Database migration required

14. **Bot API Extras**
    - Commits:
      - `e5d14880a4f2a81f4b080c3db5b4747bf20675cf`
      - `59c528b10f7bffc5342d167c4e22b5564fb4f8ee`
      - `62f159807b410956a03f1817a1417992434910d8`
    - Everything webhook
    - Enhanced bot capabilities
    - Direct message initiation

### Performance Improvements (Ongoing)

15. **Boost Speed**
    - Commit: `9276de6fdfe3d9d79ec15da8ad02cb4d6884c31f`
    - Consolidated server roundtrips

16. **Maintain Scrollbar Position**
    - Commit: `3cc84c67641fdb1b1014787cca8e2f78b034be0d`
    - Better UX

17. **Hide Empty Pings**
    - Commits:
      - `8ae11bc25e91234888f15739523166c65b268570`
      - `9d4a67dc5d5962b5ea702f1bc571fbadf71580f7`
    - Cleaner sidebar

18. **Updated Names Cache**
    - Commit: `2dd95b03dabaef0513122f74ab5b710018233d82`
    - Cache invalidation fix

19. **Rich-text on Mobile**
    - Commit: `d7ef9c9cded2a5eb547c8142707015961f817c5a`
    - Mobile editor improvements

---

## Step 5: Cherry-Pick Process

For each feature:

```bash
# 1. Create feature branch
git checkout -b feature/user-counter

# 2. View the commit
git show smallbets/master:<commit-hash>

# 3. Cherry-pick the commit
git cherry-pick <commit-hash>

# 4. If conflicts occur
git status
# Resolve conflicts manually
git add .
git cherry-pick --continue

# 5. Test thoroughly
rails test
# Manual testing in browser

# 6. Commit if you made changes
git commit -m "Add user counter feature from Small Bets"

# 7. Push and create PR
git push origin feature/user-counter

# 8. Merge to feature/smallbets-mods after approval
git checkout feature/smallbets-mods
git merge feature/user-counter
```

---

## Step 6: Manual Integration (Recommended)

For complex features, manually integrate rather than cherry-picking:

```bash
# 1. View the changes online
# Go to: https://github.com/antiwork/smallbets/commit/<commit-hash>

# 2. Create new files or modify existing ones based on the diff

# 3. Test and commit your version
git add .
git commit -m "Implement bookmarks feature (inspired by Small Bets)"
```

---

## Step 7: Testing Strategy

After each feature:

1. **Unit Tests**
   ```bash
   rails test
   ```

2. **Integration Tests**
   - Test the feature in isolation
   - Test interactions with other features

3. **Manual Testing**
   - Test in development environment
   - Test on Railway (staging)

4. **User Acceptance**
   - Deploy to production
   - Gather feedback

---

## Step 8: Documentation

For each feature added:

1. Update `CHANGELOG.md`
2. Document any new environment variables
3. Update API documentation if applicable
4. Add to README if user-facing

---

## Step 9: Database Migrations

Some features require database changes:

```bash
# Check for migrations in commits
git show <commit-hash> --stat | grep db/migrate

# Create new migration if needed
rails generate migration AddFeatureName

# Run migrations
rails db:migrate

# Test rollback
rails db:rollback
rails db:migrate
```

---

## Step 10: Deployment Process

```bash
# 1. Merge to main
git checkout main
git merge feature/smallbets-mods

# 2. Tag release
git tag -a v1.0.0-smallbets -m "Vanilla Campfire + Small Bets mods"

# 3. Push to production
git push origin main --tags

# 4. Run migrations on production
# In Railway dashboard or via CLI
rails db:migrate RAILS_ENV=production
```

---

## Quick Reference Commands

```bash
# Switch between branches
git checkout feature/sso              # Your SSO work
git checkout feature/smallbets-mods   # New development
git checkout main                     # Vanilla Campfire

# View commits
git log smallbets/master --oneline --graph

# Compare branches
git diff main feature/smallbets-mods

# Cherry-pick specific commit
git cherry-pick <commit-hash>

# Cherry-pick range of commits
git cherry-pick <start-hash>..<end-hash>

# Abort cherry-pick if issues
git cherry-pick --abort

# View file from another branch
git show smallbets/master:path/to/file.rb
```

---

## Features to Skip

These conflict with your use case or aren't needed:

1. **Email-based Auth** - You'll use OIDC instead
2. Any password-related changes - OIDC handles auth

---

## When to Return to SSO

If you need SSO functionality later:

```bash
# Option 1: Cherry-pick SSO commits into new branch
git checkout feature/smallbets-mods
git cherry-pick <sso-commit-hashes>

# Option 2: Merge SSO branch
git checkout feature/smallbets-mods
git merge feature/sso
# Resolve conflicts

# Option 3: Rebase SSO on top of new work
git checkout feature/sso
git rebase feature/smallbets-mods
```

---

## Resources

- **Small Bets Mods:** https://github.com/antiwork/smallbets/blob/master/campfire-mods.md
- **Compare View:** https://github.com/basecamp/campfire/compare/main...antiwork:smallbets:master
- **Once Campfire:** https://once.com/campfire
- **Your SSO Tag:** `sso-implementation-v1` (if tagged)

---

## Next Steps

1. ✅ Review this plan
2. ✅ Tag SSO branch for safekeeping
3. ✅ Create `feature/smallbets-mods` branch
4. ✅ Add Small Bets remote
5. ✅ Start with Phase 1 features
6. Test, commit, deploy!

---

## Notes

- Take it one feature at a time
- Test thoroughly after each addition
- Document as you go
- Don't rush - quality over speed
- Keep SSO branch for reference
- You can always merge SSO back later

Good luck with the migration! 🚀

