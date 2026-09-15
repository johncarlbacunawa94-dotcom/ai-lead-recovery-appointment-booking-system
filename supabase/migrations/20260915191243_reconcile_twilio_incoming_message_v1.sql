-- ============================================================================
-- Phase 6D
-- Deterministic Twilio inbound SMS reconciliation.
--
-- PostgreSQL remains authoritative.
-- n8n claims TWILIO_INCOMING_MESSAGE work and invokes this RPC.
--
-- Critical invariant:
--   A recognized SMS opt-out must take precedence over every prior
--   eligibility state. AI/n8n cannot reverse it.
-- ============================================================================

create or replace function public.reconcile_twilio_incoming_message_v1(
    p_outbox_event_id uuid,
    p_worker_id text
)
returns table (
    disposition text,
    next_action text,
    classification text,
    identity_disposition text,
    reason_code text,

    outbox_event_id uuid,
    raw_provider_event_id uuid,

    provider_message_id text,
    normalized_from text,
    provider_to text,

    resolved_prospect_id uuid,
    resolved_contact_point_id uuid,

    conversation_id uuid,
    message_id uuid,

    consent_event_count integer,
    review_outbox_event_id uuid
)
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
    v_outbox public.outbox_events%rowtype;
    v_raw public.raw_provider_events%rowtype;

    v_message_sid text;
    v_from text;
    v_to text;
    v_body text;
    v_body_token text;

    v_classification text;
    v_identity_disposition text;
    v_reason text;
    v_disposition text;
    v_next_action text := 'COMPLETE_OUTBOX';

    v_match_ids uuid[];
    v_match_count integer := 0;

    v_prospect_id uuid;
    v_contact_point_id uuid;

    v_conversation_id uuid;
    v_message_id uuid;

    v_external_conversation_id text;

    v_existing_message public.messages%rowtype;

    v_review public.outbox_events%rowtype;

    v_target_prospect_id uuid;
    v_target_contact_point_id uuid;

    v_purpose text;

    v_consent_event_count integer := 0;
begin
    --------------------------------------------------------------------------
    -- 1. Worker contract.
    --------------------------------------------------------------------------

    if p_outbox_event_id is null then
        raise exception
            'outbox event id is required'
            using errcode = '22023';
    end if;

    if nullif(btrim(coalesce(p_worker_id, '')), '') is null then
        raise exception
            'worker id is required'
            using errcode = '22023';
    end if;


    --------------------------------------------------------------------------
    -- 2. Lock and validate the current outbox lease.
    --------------------------------------------------------------------------

    select oe.*
    into v_outbox
    from public.outbox_events as oe
    where oe.outbox_event_id = p_outbox_event_id
    for update;

    if not found then
        raise exception
            'outbox event does not exist'
            using errcode = '22023';
    end if;

    if v_outbox.event_type is distinct from
        'TWILIO_INCOMING_MESSAGE'
    then
        raise exception
            'outbox event is not TWILIO_INCOMING_MESSAGE'
            using errcode = '22000';
    end if;

    if v_outbox.status is distinct from 'PROCESSING' then
        raise exception
            'outbox event is not PROCESSING'
            using errcode = '22000';
    end if;

    if v_outbox.locked_by is distinct from p_worker_id then
        raise exception
            'worker does not own the outbox lease'
            using errcode = '22000';
    end if;

    if v_outbox.source_raw_provider_event_id is null then
        raise exception
            'incoming message outbox has no raw provider event'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 3. Resolve authenticated raw Twilio evidence.
    --------------------------------------------------------------------------

    select rpe.*
    into v_raw
    from public.raw_provider_events as rpe
    where rpe.raw_provider_event_id =
        v_outbox.source_raw_provider_event_id;

    if not found then
        raise exception
            'raw Twilio provider event does not exist'
            using errcode = '22000';
    end if;

    if v_raw.provider is distinct from 'TWILIO' then
        raise exception
            'raw provider event is not Twilio'
            using errcode = '22000';
    end if;

    if lower(v_raw.event_type) is distinct from
        'incoming_message'
    then
        raise exception
            'raw Twilio event is not incoming_message'
            using errcode = '22000';
    end if;

    if v_raw.signature_valid is distinct from true then
        raise exception
            'raw Twilio event is not authenticated'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 4. Extract authoritative provider fields.
    --------------------------------------------------------------------------

    v_message_sid :=
        nullif(
            btrim(
                coalesce(
                    v_raw.payload ->> 'MessageSid',
                    ''
                )
            ),
            ''
        );

    v_from :=
        nullif(
            btrim(
                coalesce(
                    v_raw.payload ->> 'From',
                    ''
                )
            ),
            ''
        );

    v_to :=
        nullif(
            btrim(
                coalesce(
                    v_raw.payload ->> 'To',
                    ''
                )
            ),
            ''
        );

    v_body :=
        coalesce(
            v_raw.payload ->> 'Body',
            ''
        );

    if v_message_sid is null then
        raise exception
            'Twilio incoming message has no MessageSid'
            using errcode = '22000';
    end if;

    if v_from is null then
        raise exception
            'Twilio incoming message has no From'
            using errcode = '22000';
    end if;

    if v_to is null then
        raise exception
            'Twilio incoming message has no To'
            using errcode = '22000';
    end if;


    --------------------------------------------------------------------------
    -- 5. Deterministic keyword classification.
    --
    -- Exact normalized keywords only.
    -- No AI interpretation is permitted for opt-out state.
    --------------------------------------------------------------------------

    v_body_token :=
        upper(
            btrim(v_body)
        );

    if v_body_token in (
        'STOP',
        'STOPALL',
        'UNSUBSCRIBE',
        'CANCEL',
        'END',
        'QUIT'
    ) then
        v_classification := 'OPT_OUT';
    else
        v_classification := 'NORMAL_REPLY';
    end if;


    --------------------------------------------------------------------------
    -- 6. Replay/idempotency check.
    --
    -- If the append-only message already exists, all authoritative work from
    -- a prior committed transaction already won.
    --------------------------------------------------------------------------

    select m.*
    into v_existing_message
    from public.messages as m
    where m.provider = 'TWILIO'
      and m.provider_message_id = v_message_sid
    limit 1;

    if found then
        return query
        select
            'ALREADY_PERSISTED'::text,
            'COMPLETE_OUTBOX'::text,
            v_classification,
            'REPLAY'::text,
            'INBOUND_MESSAGE_ALREADY_PERSISTED'::text,

            v_outbox.outbox_event_id,
            v_raw.raw_provider_event_id,

            v_message_sid,
            v_from,
            v_to,

            v_existing_message.prospect_id,
            null::uuid,

            v_existing_message.conversation_id,
            v_existing_message.message_id,

            0::integer,
            null::uuid;

        return;
    end if;


    --------------------------------------------------------------------------
    -- 7. Exact phone identity lookup.
    --
    -- Match canonical prospect identities exactly as the Phase 6B resolver
    -- already does. normalized_value is intentionally not globally unique.
    --------------------------------------------------------------------------

    if v_from ~ '^\+[1-9][0-9]{7,14}$' then

        select
            array_agg(
                distinct
                case
                    when p.identity_status = 'MERGED'
                        then p.merged_into_prospect_id
                    else p.prospect_id
                end
            )
        into v_match_ids
        from public.contact_points as cp
        join public.prospects as p
          on p.prospect_id = cp.prospect_id
        where cp.contact_type = 'PHONE'
          and cp.normalized_value = v_from
          and (
              p.identity_status <> 'MERGED'
              or p.merged_into_prospect_id is not null
          );

        v_match_count :=
            coalesce(
                cardinality(v_match_ids),
                0
            );

    else
        v_match_count := 0;
    end if;


    --------------------------------------------------------------------------
    -- 8. Identity resolution.
    --------------------------------------------------------------------------

    if v_from !~ '^\+[1-9][0-9]{7,14}$' then

        v_identity_disposition :=
            'INVALID_PHONE_REVIEW';

        v_reason :=
            'INVALID_FROM_PHONE';


    elsif v_match_count > 1 then

        v_identity_disposition :=
            'AMBIGUOUS';

        v_reason :=
            'AMBIGUOUS_PHONE_IDENTITY';


    elsif v_match_count = 1 then

        v_prospect_id :=
            v_match_ids[1];

        v_identity_disposition :=
            'MATCHED_EXISTING';

        select cp.contact_point_id
        into v_contact_point_id
        from public.contact_points as cp
        where cp.prospect_id = v_prospect_id
          and cp.contact_type = 'PHONE'
          and cp.normalized_value = v_from
        order by
            cp.is_primary desc,
            cp.created_at asc
        limit 1;

        if v_contact_point_id is null then
            insert into public.contact_points (
                prospect_id,
                contact_type,
                raw_value,
                normalized_value,
                is_primary,
                verification_state
            )
            values (
                v_prospect_id,
                'PHONE',
                v_from,
                v_from,
                not exists (
                    select 1
                    from public.contact_points as cp
                    where cp.prospect_id =
                        v_prospect_id
                      and cp.contact_type =
                        'PHONE'
                ),
                'UNVERIFIED'
            )
            returning contact_point_id
            into v_contact_point_id;
        end if;


    else
        ----------------------------------------------------------------------
        -- A real authenticated inbound SMS is sufficient to create an
        -- identity shell. It is NOT explicit marketing consent.
        ----------------------------------------------------------------------

        insert into public.prospects (
            primary_location_code,
            identity_status
        )
        values (
            'UNKNOWN',
            'ACTIVE'
        )
        returning prospect_id
        into v_prospect_id;

        insert into public.contact_points (
            prospect_id,
            contact_type,
            raw_value,
            normalized_value,
            is_primary,
            verification_state
        )
        values (
            v_prospect_id,
            'PHONE',
            v_from,
            v_from,
            true,
            'UNVERIFIED'
        )
        returning contact_point_id
        into v_contact_point_id;

        v_identity_disposition :=
            'CREATED_NEW';

        v_reason :=
            'NEW_INBOUND_SMS_IDENTITY';
    end if;


    --------------------------------------------------------------------------
    -- 9. OPT-OUT authority.
    --
    -- A recognized keyword wins even when identity is ambiguous.
    --
    -- For every canonical prospect represented by the exact phone:
    --   - ensure a canonical phone contact exists;
    --   - set every SMS purpose INELIGIBLE + DND + REVOKED;
    --   - append one consent provenance event per canonical contact.
    --
    -- This deliberately does NOT rely on AI or n8n interpretation.
    --------------------------------------------------------------------------

    if v_classification = 'OPT_OUT'
       and v_from ~ '^\+[1-9][0-9]{7,14}$'
    then

        ----------------------------------------------------------------------
        -- If no pre-existing match existed, the newly created prospect is
        -- already the only authoritative target.
        ----------------------------------------------------------------------

        if v_match_count = 0 then
            v_match_ids :=
                array[v_prospect_id];

            v_match_count := 1;
        end if;


        foreach v_target_prospect_id
            in array v_match_ids
        loop
            v_target_contact_point_id := null;

            select cp.contact_point_id
            into v_target_contact_point_id
            from public.contact_points as cp
            where cp.prospect_id =
                    v_target_prospect_id
              and cp.contact_type =
                    'PHONE'
              and cp.normalized_value =
                    v_from
            order by
                cp.is_primary desc,
                cp.created_at asc
            limit 1;

            if v_target_contact_point_id is null then
                insert into public.contact_points (
                    prospect_id,
                    contact_type,
                    raw_value,
                    normalized_value,
                    is_primary,
                    verification_state
                )
                values (
                    v_target_prospect_id,
                    'PHONE',
                    v_from,
                    v_from,
                    not exists (
                        select 1
                        from public.contact_points as cp
                        where cp.prospect_id =
                            v_target_prospect_id
                          and cp.contact_type =
                            'PHONE'
                    ),
                    'UNVERIFIED'
                )
                returning contact_point_id
                into v_target_contact_point_id;
            end if;


            foreach v_purpose in array array[
                'INBOUND_RESPONSE',
                'OUTBOUND_SALES',
                'REACTIVATION',
                'APPOINTMENT_RECOVERY'
            ]::text[]
            loop
                insert into public.contact_eligibility (
                    prospect_id,
                    contact_point_id,
                    channel,
                    purpose,
                    eligibility_state,
                    dnd,
                    consent_basis,
                    provenance_source,
                    provenance_reference,
                    reason_code,
                    effective_at,
                    expires_at
                )
                values (
                    v_target_prospect_id,
                    v_target_contact_point_id,
                    'SMS',
                    v_purpose,
                    'INELIGIBLE',
                    true,
                    'REVOKED',
                    'TWILIO_INCOMING_MESSAGE',
                    v_message_sid,
                    'SMS_OPT_OUT_KEYWORD',
                    v_raw.received_at,
                    null
                )
                on conflict (
                    prospect_id,
                    contact_point_id,
                    channel,
                    purpose
                )
                where contact_point_id is not null
                do update
                set
                    eligibility_state =
                        'INELIGIBLE',

                    dnd =
                        true,

                    consent_basis =
                        'REVOKED',

                    provenance_source =
                        'TWILIO_INCOMING_MESSAGE',

                    provenance_reference =
                        excluded.provenance_reference,

                    reason_code =
                        'SMS_OPT_OUT_KEYWORD',

                    effective_at =
                        excluded.effective_at,

                    expires_at =
                        null;
            end loop;


            insert into public.consent_events (
                prospect_id,
                contact_point_id,
                channel,
                purpose,
                action,
                source,
                source_event_id,
                evidence_reference,
                evidence_summary,
                occurred_at
            )
            values (
                v_target_prospect_id,
                v_target_contact_point_id,
                'SMS',
                null,
                'OPT_OUT',
                'TWILIO_INCOMING_MESSAGE',
                'twilio-message:' ||
                    v_message_sid ||
                    ':opt-out:' ||
                    v_target_contact_point_id::text,
                v_raw.raw_provider_event_id::text,
                'Authenticated inbound Twilio SMS contained a recognized deterministic opt-out keyword.',
                v_raw.received_at
            )
            on conflict (
                source,
                source_event_id
            )
            where source_event_id is not null
            do nothing;

            if found then
                v_consent_event_count :=
                    v_consent_event_count + 1;
            end if;
        end loop;


        v_disposition :=
            'OPT_OUT_APPLIED';

        v_reason :=
            'SMS_OPT_OUT_APPLIED';
    end if;


    --------------------------------------------------------------------------
    -- 10. Persist the SMS conversation/message.
    --
    -- Resolved identities use a stable participant-pair conversation.
    -- Ambiguous/invalid identities get an isolated provider-message session
    -- rather than attaching the message to the wrong prospect.
    --------------------------------------------------------------------------

    if v_prospect_id is not null
       and v_identity_disposition <> 'AMBIGUOUS'
       and v_identity_disposition <> 'INVALID_PHONE_REVIEW'
    then
        v_external_conversation_id :=
            'TWILIO_SMS:' ||
            v_from ||
            ':' ||
            v_to;
    else
        v_external_conversation_id :=
            'TWILIO_SMS_UNRESOLVED:' ||
            v_message_sid;
    end if;


    select c.conversation_id
    into v_conversation_id
    from public.conversations as c
    where c.provider = 'TWILIO'
      and c.external_conversation_id =
            v_external_conversation_id
    limit 1;


    if v_conversation_id is null then
        insert into public.conversations as inserted_conversation (
            prospect_id,
            channel,
            provider,
            external_conversation_id,
            state,
            started_at
        )
        values (
            case
                when v_identity_disposition in (
                    'AMBIGUOUS',
                    'INVALID_PHONE_REVIEW'
                )
                    then null
                else v_prospect_id
            end,
            'SMS',
            'TWILIO',
            v_external_conversation_id,
            'ACTIVE',
            v_raw.received_at
        )
        on conflict (
            provider,
            external_conversation_id
        )
        where external_conversation_id is not null
        do nothing
        returning inserted_conversation.conversation_id
        into v_conversation_id;

        if v_conversation_id is null then
            select c.conversation_id
            into v_conversation_id
            from public.conversations as c
            where c.provider = 'TWILIO'
              and c.external_conversation_id =
                    v_external_conversation_id;

            if v_conversation_id is null then
                raise exception
                    'Twilio inbound conversation race could not be resolved'
                    using errcode = 'P0001';
            end if;
        end if;
    end if;


    insert into public.messages as inserted_message (
        conversation_id,
        prospect_id,
        provider,
        provider_message_id,
        channel,
        direction,
        role,
        body,
        structured_content,
        occurred_at
    )
    values (
        v_conversation_id,

        case
            when v_identity_disposition in (
                'AMBIGUOUS',
                'INVALID_PHONE_REVIEW'
            )
                then null
            else v_prospect_id
        end,

        'TWILIO',
        v_message_sid,
        'SMS',
        'INBOUND',
        'CALLER',
        v_body,

        jsonb_build_object(
            'source',
            'TWILIO_INCOMING_MESSAGE',

            'source_outbox_event_id',
            v_outbox.outbox_event_id,

            'raw_provider_event_id',
            v_raw.raw_provider_event_id,

            'from',
            v_from,

            'to',
            v_to,

            'classification',
            v_classification,

            'identity_disposition',
            v_identity_disposition,

            'num_media',
            coalesce(
                v_raw.payload ->> 'NumMedia',
                '0'
            )
        ),

        v_raw.received_at
    )
    on conflict do nothing
    returning inserted_message.message_id
    into v_message_id;


    if v_message_id is null then
        select m.message_id
        into v_message_id
        from public.messages as m
        where m.provider = 'TWILIO'
          and m.provider_message_id =
                v_message_sid;

        if v_message_id is null then
            raise exception
                'Twilio inbound message race could not be resolved'
                using errcode = 'P0001';
        end if;
    end if;


    --------------------------------------------------------------------------
    -- 11. Review routing.
    --
    -- Normal ambiguous/invalid replies require human review.
    -- An ambiguous STOP has already revoked every exact matching canonical
    -- identity above, so review is informational and cannot delay blocking.
    --------------------------------------------------------------------------

    if v_identity_disposition in (
        'AMBIGUOUS',
        'INVALID_PHONE_REVIEW'
    ) then

        insert into public.outbox_events (
            event_key,
            event_type,
            aggregate_type,
            aggregate_id,
            source_raw_provider_event_id,
            correlation_id,
            payload
        )
        values (
            v_outbox.event_key ||
                ':REVIEW',

            'TWILIO_INCOMING_MESSAGE_REVIEW_REQUIRED',

            'MESSAGE',
            v_message_id,

            v_raw.raw_provider_event_id,
            v_outbox.correlation_id,

            jsonb_build_object(
                'source_outbox_event_id',
                v_outbox.outbox_event_id,

                'provider_message_id',
                v_message_sid,

                'message_id',
                v_message_id,

                'normalized_from',
                v_from,

                'classification',
                v_classification,

                'identity_disposition',
                v_identity_disposition,

                'reason_code',
                v_reason
            )
        )
        on conflict on constraint
            outbox_events_event_key_unique
        do nothing
        returning *
        into v_review;


        if not found then
            select oe.*
            into v_review
            from public.outbox_events as oe
            where oe.event_key =
                v_outbox.event_key ||
                ':REVIEW';
        end if;


        if v_classification = 'OPT_OUT' then
            v_disposition :=
                'OPT_OUT_APPLIED_REVIEW_REQUIRED';

            v_reason :=
                'SMS_OPT_OUT_APPLIED_AMBIGUOUS_IDENTITY';
        else
            v_disposition :=
                'REVIEW_REQUIRED';

            v_reason :=
                case
                    when v_identity_disposition =
                        'INVALID_PHONE_REVIEW'
                        then 'INVALID_FROM_PHONE'
                    else 'AMBIGUOUS_PHONE_IDENTITY'
                end;
        end if;

    elsif v_classification = 'NORMAL_REPLY' then
        v_disposition :=
            'PERSISTED';

        v_reason :=
            case
                when v_identity_disposition =
                    'CREATED_NEW'
                    then 'NEW_INBOUND_SMS_PERSISTED'
                else 'INBOUND_SMS_PERSISTED'
            end;
    end if;


    --------------------------------------------------------------------------
    -- 12. Return authoritative result.
    --
    -- Generic outbox completion remains owned by the async worker.
    --------------------------------------------------------------------------

    return query
    select
        v_disposition,
        v_next_action,
        v_classification,
        v_identity_disposition,
        v_reason,

        v_outbox.outbox_event_id,
        v_raw.raw_provider_event_id,

        v_message_sid,
        v_from,
        v_to,

        case
            when v_identity_disposition in (
                'AMBIGUOUS',
                'INVALID_PHONE_REVIEW'
            )
                then null::uuid
            else v_prospect_id
        end,

        case
            when v_identity_disposition in (
                'AMBIGUOUS',
                'INVALID_PHONE_REVIEW'
            )
                then null::uuid
            else v_contact_point_id
        end,

        v_conversation_id,
        v_message_id,

        v_consent_event_count,

        case
            when v_review.outbox_event_id is null
                then null::uuid
            else v_review.outbox_event_id
        end;
end;
$function$;


comment on function
public.reconcile_twilio_incoming_message_v1(
    uuid,
    text
)
is
'Phase 6D authoritative Twilio inbound SMS reconciliation. Validates the claimed authenticated incoming-message outbox event, performs deterministic phone identity resolution, persists the inbound SMS, atomically applies recognized opt-out/DND state before any downstream work, and creates review work for ambiguous identities.';


revoke all
on function
public.reconcile_twilio_incoming_message_v1(
    uuid,
    text
)
from public;

revoke all
on function
public.reconcile_twilio_incoming_message_v1(
    uuid,
    text
)
from anon;

revoke all
on function
public.reconcile_twilio_incoming_message_v1(
    uuid,
    text
)
from authenticated;

grant execute
on function
public.reconcile_twilio_incoming_message_v1(
    uuid,
    text
)
to service_role;