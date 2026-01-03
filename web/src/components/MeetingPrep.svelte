<script>
  import { createEventDispatcher } from 'svelte';
  import { meetingPrep } from '../lib/stores.js';

  const dispatch = createEventDispatcher();

  // Form state
  let meetingType = 'sales_call';
  let attendeesText = '';
  let objectivesText = '';
  let talkingPointsText = '';
  let competitorsText = '';
  let customRemindersText = '';
  let pricingNotes = '';
  let discountAuthority = '';
  let additionalContext = '';

  const meetingTypes = [
    { value: 'sales_call', label: 'Sales Call' },
    { value: 'product_demo', label: 'Product Demo' },
    { value: 'discovery_call', label: 'Discovery Call' },
    { value: 'negotiation', label: 'Negotiation' },
    { value: 'customer_success', label: 'Customer Success' },
    { value: 'internal_meeting', label: 'Internal Meeting' },
    { value: 'one_on_one', label: '1:1 Meeting' },
  ];

  function parseAttendees(text) {
    return text
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line)
      .map((line) => {
        // Parse format: "Name (Role) at Company - notes"
        const match = line.match(/^([^(]+?)(?:\s*\(([^)]+)\))?(?:\s*at\s+([^-]+))?(?:\s*-\s*(.+))?$/);
        if (match) {
          return {
            name: match[1].trim(),
            role: match[2]?.trim() || null,
            company: match[3]?.trim() || null,
            notes: match[4]?.trim() || null,
          };
        }
        return { name: line, role: null, company: null, notes: null };
      });
  }

  function parseTalkingPoints(text) {
    return text
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line)
      .map((line, index) => {
        // Parse format: "[priority] topic - notes" or just "topic"
        const priorityMatch = line.match(/^\[(\d)\]\s*(.+)$/);
        const notesMatch = line.match(/^(.+?)\s*-\s*(.+)$/);

        let topic = line;
        let priority = 2; // default medium
        let notes = null;

        if (priorityMatch) {
          priority = parseInt(priorityMatch[1], 10);
          topic = priorityMatch[2];
        }

        const topicNotesMatch = topic.match(/^(.+?)\s*-\s*(.+)$/);
        if (topicNotesMatch) {
          topic = topicNotesMatch[1];
          notes = topicNotesMatch[2];
        }

        return { topic: topic.trim(), priority, notes };
      });
  }

  function parseList(text) {
    return text
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line);
  }

  function handleSubmit() {
    const prepData = {
      meeting_type: meetingType,
      attendees: parseAttendees(attendeesText),
      objectives: parseList(objectivesText),
      talking_points: parseTalkingPoints(talkingPointsText),
      competitors: parseList(competitorsText),
      custom_reminders: parseList(customRemindersText),
      pricing_notes: pricingNotes || null,
      discount_authority: discountAuthority || null,
      additional_context: additionalContext || null,
    };

    dispatch('submit', prepData);
  }

  function handleSkip() {
    dispatch('skip');
  }
</script>

<div class="meeting-prep">
  <h2>Meeting Prep</h2>
  <p class="subtitle">Enter context about your meeting to get personalized coaching.</p>

  <form on:submit|preventDefault={handleSubmit}>
    <div class="form-group">
      <label for="meeting-type">Meeting Type</label>
      <select id="meeting-type" bind:value={meetingType}>
        {#each meetingTypes as type}
          <option value={type.value}>{type.label}</option>
        {/each}
      </select>
    </div>

    <div class="form-group">
      <label for="attendees">
        Attendees
        <span class="hint">One per line: Name (Role) at Company - notes</span>
      </label>
      <textarea
        id="attendees"
        bind:value={attendeesText}
        rows="3"
        placeholder="John Smith (VP Sales) at Acme Corp - decision maker&#10;Jane Doe (Engineer) - technical evaluator"
      ></textarea>
    </div>

    <div class="form-group">
      <label for="objectives">
        Meeting Objectives
        <span class="hint">One per line</span>
      </label>
      <textarea
        id="objectives"
        bind:value={objectivesText}
        rows="2"
        placeholder="Understand their current workflow&#10;Schedule a demo with the team"
      ></textarea>
    </div>

    <div class="form-group">
      <label for="talking-points">
        Talking Points to Cover
        <span class="hint">[1]=high, [2]=medium, [3]=low priority. Add - notes for context.</span>
      </label>
      <textarea
        id="talking-points"
        bind:value={talkingPointsText}
        rows="4"
        placeholder="[1] Integration capabilities - key differentiator&#10;[1] Pricing and timeline&#10;[2] Security certifications&#10;[3] Roadmap features"
      ></textarea>
    </div>

    <div class="form-group">
      <label for="competitors">
        Competitors to Watch For
        <span class="hint">One per line</span>
      </label>
      <textarea
        id="competitors"
        bind:value={competitorsText}
        rows="2"
        placeholder="Datadog&#10;Splunk&#10;New Relic"
      ></textarea>
    </div>

    <div class="form-row">
      <div class="form-group">
        <label for="pricing-notes">Pricing Notes</label>
        <input
          id="pricing-notes"
          type="text"
          bind:value={pricingNotes}
          placeholder="Standard pricing, 10% volume discount available"
        />
      </div>

      <div class="form-group">
        <label for="discount-authority">Discount Authority</label>
        <input
          id="discount-authority"
          type="text"
          bind:value={discountAuthority}
          placeholder="Up to 15%, need approval for more"
        />
      </div>
    </div>

    <div class="form-group">
      <label for="custom-reminders">
        Custom Reminders
        <span class="hint">One per line</span>
      </label>
      <textarea
        id="custom-reminders"
        bind:value={customRemindersText}
        rows="2"
        placeholder="Ask about their Q2 budget cycle&#10;Mention the case study with similar company"
      ></textarea>
    </div>

    <div class="form-group">
      <label for="additional-context">Additional Context</label>
      <textarea
        id="additional-context"
        bind:value={additionalContext}
        rows="2"
        placeholder="Any other context that might be helpful..."
      ></textarea>
    </div>

    <div class="form-actions">
      <button type="button" class="secondary" on:click={handleSkip}>
        Skip for now
      </button>
      <button type="submit" class="primary">
        Save &amp; Start Recording
      </button>
    </div>
  </form>
</div>

<style>
  .meeting-prep {
    max-width: 600px;
    margin: 0 auto;
    padding: 2rem;
  }

  h2 {
    margin-bottom: 0.5rem;
  }

  .subtitle {
    color: var(--color-text-muted);
    margin-bottom: 1.5rem;
  }

  .form-group {
    margin-bottom: 1rem;
  }

  .form-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
  }

  label {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  .hint {
    font-size: 0.75rem;
    font-weight: 400;
    color: var(--color-text-muted);
  }

  textarea {
    resize: vertical;
    min-height: 60px;
  }

  .form-actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.75rem;
    margin-top: 1.5rem;
    padding-top: 1.5rem;
    border-top: 1px solid var(--color-border);
  }
</style>
