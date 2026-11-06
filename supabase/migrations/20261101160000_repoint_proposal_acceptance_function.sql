CREATE OR REPLACE FUNCTION public.create_todo_on_proposal_acceptance()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'accepted' AND (OLD.status IS NULL OR OLD.status != 'accepted') THEN
    INSERT INTO public.todo_list (
      task_id,
      worker_id,
      title,
      description,
      priority,
      due_date,
      details,
      status
    )
    SELECT
      t.id,
      NEW.worker_id,
      t.title,
      t.description,
      t.priority,
      t.due_date,
      jsonb_build_object(
        'category_original', t.category,
        'estimated_time_original', t.estimated_time,
        'payment_terms_original', t.payment_terms,
        'budget_original', t.budget,
        'category', COALESCE(NEW.proposed_category, t.category),
        'estimated_time', COALESCE(NEW.proposed_estimated_time, t.estimated_time),
        'payment_terms', COALESCE(NEW.proposed_payment_terms, t.payment_terms),
        'budget', NEW.quoted_price,
        'timeline', NEW.proposed_timeline,
        'negotiation_notes', NEW.proposal_notes
      ),
      'pending'::character varying
    FROM tasks t
    WHERE t.id = NEW.task_id
    AND NOT EXISTS (
      SELECT 1 FROM todo_list tl
      WHERE tl.task_id = NEW.task_id AND tl.worker_id = NEW.worker_id
    );

    INSERT INTO public.notifications (user_id, task_id, type, message)
    SELECT
      up.user_id,
      NEW.task_id,
      'proposal_accepted'::character varying,
      'Your proposal has been accepted! Check your todo list for the agreed terms.'
    FROM user_profiles up
    WHERE up.id = NEW.worker_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

notify pgrst, 'reload schema';
