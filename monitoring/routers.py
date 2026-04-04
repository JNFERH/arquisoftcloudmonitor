class CostsRouter:
    """
    Routes CostRecord and Organization models to costs_db.
    Everything else (auth, sessions) goes to default.
    """

    costs_apps = {'dashboard'}

    def db_for_read(self, model, **hints):
        if model._meta.app_label in self.costs_apps:
            return 'costs_db'
        return 'default'

    def db_for_write(self, model, **hints):
        if model._meta.app_label in self.costs_apps:
            return 'costs_db'
        return 'default'

    def allow_relation(self, obj1, obj2, **hints):
        return True

    def allow_migrate(self, db, app_label, model_name=None, **hints):
        if app_label in self.costs_apps:
            return db == 'costs_db'
        return db == 'default'