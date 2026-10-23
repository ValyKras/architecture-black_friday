const admin = db.getSiblingDB("admin");

try {
  const status = admin.runCommand({ replSetGetStatus: 1 });
  if (status.ok === 1) {
    print("Config replica set is already initialized.");
    quit(0);
  }
} catch (error) {
  // An uninitialized replica set reports an error; initiate it below.
}

const result = admin.runCommand({
  replSetInitiate: {
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27017" }],
  },
});

if (result.ok !== 1) {
  printjson(result);
  quit(1);
}
print("Initialized config_server replica set.");
