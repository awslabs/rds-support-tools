/*
 *  Copyright 2016 Amazon.com, Inc. or its affiliates. 
 *  All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License"). 
 *  You may not use this file except in compliance with the License. 
 *  A copy of the License is located at
 * 
 *      http://aws.amazon.com/apache2.0/
 * 
 * or in the "license" file accompanying this file. 
 * This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
 * either express or implied. See the License for the specific language governing permissions 
 * and limitations under the License.
*/

import java.sql.*;

public class RDSDatabaseConnection {

  // The JDBC Driver is Engine specific, and should be reviewed to make sure you are using the correct JDBC_DRIVER string.
  // This driver is what will ensure that the java.sql.* commands work correctly with the intended DB engine.

  // MySQL: Is what we will use for this demonstration.
  static final String JDBC_DRIVER = "com.mysql.jdbc.Driver"; 

  // Here are some examples of what it would look like in Oracle or PostgreSQL connections.
  /* Oracle
  static final String JDBC_DRIVER = "oracle.jdbc.driver.OracleDriver";
  */
  /* PostgreSQL
  static final String JDBC_DRIVER = "org.postgresql.Driver";
  */

  // Keep in mind that this preface is also Engine specific based on the needs of the Engine.
  static final String DB_URL_PREFACE = "jdbc:mysql://";
  // Oracle for example uses "jdbc:oracle:<drivertype>:@<host>:<port>:<database>"
  // MySQL's full string is "jdbc:mysql://<host>:<port>/<database>"
  // PostgreSQL's full string is "jdbc:postgresql://<host>:<port>/<database>"

  public static void main(String[] args) {

    /* In order to make our program dynamic for multiple MySQL database's and credentials, We will run the java program with
    * the following order:
    * $ java RDSDatabaseConnection <hostname> <port> <user> <pass> <database>
    * ie:
    * $ java RDSDatabaseConnection myFirstDB.123456789012.us-west-2.rds.amazonaws.com 3306 myRDSUser pA55w0Rd exampleDatabase
    */

    // Initializing the variables which we will pull from the launch arguments
    String hostname = null;
    String port = null;
    String user = null;
    String pass = null;
    String database = null;

    try{
      hostname = args[0];
      port = args[1];
      user = args[2];
      pass = args[3];
      database = args[4];
    } catch(ArrayIndexOutOfBoundsException e) {
      System.out.println("Not enough arguments provided. Be sure to input as indicated:");
      System.out.println(" java RDSDatabaseConnection <host> <port> <username> <password> <database>");
    }
    Connection conn = null;
    Statement stmt = null;

    try{
      // Registering the JDBC driver
      Class.forName(JDBC_DRIVER);

      // In order to execute a statement, we will initiate a database connection:

      System.out.print("Connecting to " + hostname + "...");
      // DriverManager.getConnection takes the arguments (DB_URL, USER, PASS),
      // Keep in mind from above that the look of DB_URL changes per engine. Below is for MySQL:
      conn = DriverManager.getConnection(DB_URL_PREFACE + hostname + ":" + port + "/" + database, user, pass);
      System.out.println("SUCCESS");
      
      /* Creating a table, insertion, select, and other types of SQL statements are all handled the same way
       * by passing the statement string into executeUpdate from a Statement built off of our open connection.
       * Here is an example by creating a table:
       */

      System.out.print("Creating table in given database...");
      stmt = conn.createStatement();
      
      String sql = "CREATE TABLE myTable " +
                   "(id INTEGER not NULL, " +
                   " someStuff VARCHAR(255), " + 
                   " moreStuff VARCHAR(255), " + 
                   " PRIMARY KEY ( id ))"; 

      stmt.executeUpdate(sql);
      System.out.println("SUCCESS");

      System.out.print("Inserting data into table...");
      sql = "INSERT INTO myTable " +
                   "(id, someStuff, moreStuff)" +
                   "VALUES " +
                   "(1, 'This is some stuff', 'This is more stuff')," +
                   "(2, 'This is also some stuff', 'This is also more stuff')";
      stmt.executeUpdate(sql);
      System.out.println("SUCCESS");

      // It's important to note that executeUpdate(String) is only to be used with SQL statements that return nothing.
      // stmt.executeQuery(String) will return a ResultSet object, such as a SELECT statement.

      System.out.println("Getting data from table...");
      sql = "SELECT * FROM myTable ORDER BY id DESC";
      ResultSet results = stmt.executeQuery(sql);

      System.out.println("ID | someStuff | moreStuff");
      while (results.next()){
        System.out.print(results.getString("id") + " | ");
        System.out.print(results.getString("someStuff") + " | ");
        System.out.println(results.getString("moreStuff"));
      }
      System.out.println("End of Data from table");

    }catch(SQLException se){
      System.out.println("A SQL error has occurred:");
      se.printStackTrace();
    }catch(Exception e){
      e.printStackTrace();
    }finally{
      // Once everything has finished running, even when errors are caught, we should make sure the JDBC connection is closed.
      try{
         if(stmt!=null)
            conn.close();
      }catch(SQLException se){
      }
      try{
         if(conn!=null){
            conn.close();
            System.out.println("Connection to database is closed.");
         }

      }catch(SQLException se){
         se.printStackTrace();
      }
    }
  }
}